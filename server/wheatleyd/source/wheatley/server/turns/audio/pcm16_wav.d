module wheatley.server.turns.audio.pcm16_wav;

import std.array : Appender, appender;
import std.file : write;

import wheatley.common.runtime.temp_files : temporaryRuntimeFile;

string temporarySttWavPath(string appDataRoot, string phase)
{
    return temporaryRuntimeFile(appDataRoot, "wheatleyd", "audio-processing", "stt-" ~ phase, ".wav");
}

void writePcm16Wav(string path, const(short)[] samples, int sampleRate, ushort channels)
{
    write(path, pcm16WavBytes(samples, sampleRate, channels));
}

ubyte[] pcm16WavBytes(const(short)[] samples, int sampleRate, ushort channels)
{
    auto dataBytes = cast(uint) (samples.length * 2);
    auto outp = appender!(ubyte[])();
    putAscii(outp, "RIFF");
    putLe32(outp, 36 + dataBytes);
    putAscii(outp, "WAVEfmt ");
    putLe32(outp, 16);
    putLe16(outp, 1);
    putLe16(outp, channels);
    putLe32(outp, cast(uint) sampleRate);
    putLe32(outp, cast(uint) (sampleRate * channels * 2));
    putLe16(outp, cast(ushort) (channels * 2));
    putLe16(outp, 16);
    putAscii(outp, "data");
    putLe32(outp, dataBytes);
    foreach (sample; samples) {
        putLe16(outp, cast(ushort) sample);
    }
    return outp.data;
}

ubyte[] pcm16RawBytes(const(short)[] samples)
{
    auto outp = appender!(ubyte[])();
    foreach (sample; samples) {
        putLe16(outp, cast(ushort) sample);
    }
    return outp.data;
}

double pcm16SampleDurationSeconds(const(short)[] samples, int sampleRate = 16_000, ushort channels = 1)
{
    if (sampleRate <= 0 || channels == 0) return 0.0;
    return cast(double) samples.length / cast(double) (sampleRate * channels);
}

private void putAscii(ref Appender!(ubyte[]) outp, string value)
{
    outp.put(cast(ubyte[]) value);
}

private void putLe16(ref Appender!(ubyte[]) outp, ushort value)
{
    outp.put(cast(ubyte) (value & 0xff));
    outp.put(cast(ubyte) ((value >> 8) & 0xff));
}

private void putLe32(ref Appender!(ubyte[]) outp, uint value)
{
    outp.put(cast(ubyte) (value & 0xff));
    outp.put(cast(ubyte) ((value >> 8) & 0xff));
    outp.put(cast(ubyte) ((value >> 16) & 0xff));
    outp.put(cast(ubyte) ((value >> 24) & 0xff));
}

unittest
{
    short[] samples = [cast(short) 0, cast(short) 32767, cast(short) -32768];
    auto wav = pcm16WavBytes(samples, 16_000, 1);
    assert(wav.length == 44 + samples.length * 2);
    assert(wav[0] == 'R' && wav[1] == 'I' && wav[2] == 'F' && wav[3] == 'F');
    assert(wav[8] == 'W' && wav[9] == 'A' && wav[10] == 'V' && wav[11] == 'E');
    assert(wav[36] == 'd' && wav[37] == 'a' && wav[38] == 't' && wav[39] == 'a');
    assert(pcm16RawBytes(samples).length == samples.length * 2);
    assert(pcm16SampleDurationSeconds(samples, 16_000, 1) == 3.0 / 16_000.0);
}
