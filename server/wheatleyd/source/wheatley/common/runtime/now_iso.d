module wheatley.common.runtime.now_iso;

import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.format : format;

string nowIso()
{
    auto now = Clock.currTime(UTC());
    return format!"%04d-%02d-%02dT%02d:%02d:%02d.%06dZ"(
        now.year,
        cast(int) now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
        now.fracSecs.total!"usecs",
    );
}
