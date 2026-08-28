module wheatley.client.console.ui.output;

version (Posix) {
    import core.sys.posix.sys.ioctl : TIOCGWINSZ, ioctl, winsize;
    import core.sys.posix.unistd : isatty;
}

import std.array : appender, replicate;
import std.conv : ConvException, to;
import std.process : environment;
import std.stdio : stderr, stdout;
import std.string : split, splitLines, strip;

string color(string text, string name)
{
    auto code = colorCode(name);
    return code.length ? "\033[" ~ code ~ "m" ~ text ~ "\033[0m" : text;
}

string prefix(string name, string colorName)
{
    return color(name ~ ">", colorName);
}

void writePrompt(string name, string colorName)
{
    stdout.write(prefix(name, colorName));
    stdout.flush();
}

void writeAssistantPrefix(string name)
{
    writePrompt(name, "orange");
}

void writeToken(string token)
{
    stdout.write(token);
    stdout.flush();
}

void writeLine()
{
    stdout.write("\n");
    stdout.flush();
}

void writeNotice(string text, string colorName = "green")
{
    stdout.write(color(text, colorName), "\n");
    stdout.flush();
}

void writeTurn(string name, string text, string colorName = "orange")
{
    stdout.write(prefix(name, colorName), text, "\n");
    stdout.flush();
}

void writeMutedTurn(string name, string text)
{
    stdout.write(color(name ~ ">" ~ text, "gray"), "\n");
    stdout.flush();
}

void writeTimedTurn(
    string name,
    string text,
    string duration,
    string colorName = "orange",
)
{
    stdout.write(
        prefix(name, colorName),
        text,
        duration.length ? " " ~ color(duration, "gray") : "",
        "\n",
    );
    stdout.flush();
}

void writeSystemTurn(string text)
{
    stdout.write(prefix("system", "light_blue"), text, "\n");
    stdout.flush();
}

void writeWrappedTurn(string name, string text, string colorName = "orange")
{
    writeWrappedBlock(name, colorName, text, true);
}

void writeError(string message)
{
    stderr.write(prefix("error", "red"), message, "\n");
    stderr.flush();
}

final class LivePreviewLine
{
    private bool active;
    private size_t renderedRows;

    void begin(string name, string colorName)
    {
        if (active) return;
        renderedRows = writeWrappedBlock(name, colorName, "", false);
        stdout.flush();
        active = true;
    }

    void update(string name, string colorName, string text)
    {
        auto clean = text.strip;
        if (!clean.length) return;

        clearRenderedBlock();
        renderedRows = writeWrappedBlock(name, colorName, clean, false);
        stdout.flush();
        active = true;
    }

    void updateNotice(string text, string colorName)
    {
        auto clean = text.strip;
        if (!clean.length) return;

        clearRenderedBlock();
        renderedRows = writeNoticeBlock(clean, colorName, false);
        stdout.flush();
        active = true;
    }

    void completeTurn(string name, string colorName, string text)
    {
        clearRenderedBlock();
        writeWrappedBlock(name, colorName, text, true);
        active = false;
        renderedRows = 0;
    }

    void clear()
    {
        if (!active) return;
        clearRenderedBlock();
        stdout.flush();
        active = false;
        renderedRows = 0;
    }

    private void clearRenderedBlock()
    {
        if (!active || !renderedRows) return;
        replaceBlock(renderedRows);
        renderedRows = 0;
    }
}

private void replaceLine()
{
    stdout.write("\r\033[2K");
}

private void replaceBlock(size_t rows)
{
    if (!rows) return;
    stdout.write("\r\033[2K");
    foreach (_; 1 .. rows) {
        stdout.write("\033[1A\r\033[2K");
    }
}

private size_t temporaryLineColumns()
{
    auto columns = terminalColumns();
    return cast(size_t) (columns > 2 ? columns - 2 : 1);
}

private size_t writeWrappedBlock(string name, string colorName, string text, bool newline)
{
    auto plainPrefix = name ~ ">";
    auto rows = wrappedRows(text, contentColumns(plainPrefix.length));
    stdout.write(prefix(name, colorName));
    foreach (index, row; rows) {
        if (index) stdout.write("\n", replicate(" ", plainPrefix.length));
        stdout.write(row);
    }
    if (newline) stdout.write("\n");
    return rows.length;
}

private size_t writeNoticeBlock(string text, string colorName, bool newline)
{
    auto rows = wrappedRows(text, temporaryLineColumns());
    foreach (index, row; rows) {
        if (index) stdout.write("\n");
        stdout.write(color(row, colorName));
    }
    if (newline) stdout.write("\n");
    return rows.length;
}

private size_t contentColumns(size_t plainPrefixColumns)
{
    auto columns = temporaryLineColumns();
    if (columns <= plainPrefixColumns + 8) return 8;
    return columns - plainPrefixColumns;
}

private string[] wrappedRows(string text, size_t maxColumns)
{
    if (!text.length) return [""];
    if (!maxColumns) maxColumns = 1;

    string[] rows;
    foreach (line; text.splitLines) {
        auto lineRows = wrappedLogicalLine(line, maxColumns);
        rows ~= lineRows.length ? lineRows : [""];
    }
    return rows.length ? rows : [""];
}

private string[] wrappedLogicalLine(string text, size_t maxColumns)
{
    if (!text.length) return [""];

    string[] rows;
    auto words = text.split;
    auto current = appender!string;
    size_t currentColumns;

    void pushCurrent()
    {
        if (!current.data.length) return;
        rows ~= current.data;
        current = appender!string;
        currentColumns = 0;
    }

    foreach (word; words) {
        auto wordColumns = visibleColumns(word);
        if (wordColumns > maxColumns) {
            pushCurrent();
            foreach (part; splitLongWord(word, maxColumns)) {
                rows ~= part;
            }
            continue;
        }

        auto needed = currentColumns ? currentColumns + 1 + wordColumns : wordColumns;
        if (currentColumns && needed > maxColumns) {
            pushCurrent();
        }
        if (currentColumns) {
            current.put(" ");
            currentColumns++;
        }
        current.put(word);
        currentColumns += wordColumns;
    }
    pushCurrent();
    return rows.length ? rows : [""];
}

private string[] splitLongWord(string word, size_t maxColumns)
{
    string[] rows;
    auto current = appender!string;
    size_t columns;
    foreach (dchar ch; word) {
        if (columns >= maxColumns) {
            rows ~= current.data;
            current = appender!string;
            columns = 0;
        }
        current.put(ch);
        columns++;
    }
    if (current.data.length) rows ~= current.data;
    return rows;
}

private size_t visibleColumns(string text)
{
    size_t columns;
    foreach (dchar ch; text) {
        columns++;
    }
    return columns;
}

private int terminalColumns()
{
    version (Posix) {
        auto fd = stdout.fileno;
        if (isatty(fd)) {
            winsize size;
            if (ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col > 0) {
                return cast(int) size.ws_col;
            }
        }
    }

    auto value = environment.get("COLUMNS", "");
    if (value.length) {
        try {
            auto columns = value.to!int;
            if (columns > 0) return columns;
        } catch (ConvException) {
        }
    }
    return 120;
}

private string colorCode(string name)
{
    switch (name) {
        case "green": return "32";
        case "red": return "31";
        case "yellow": return "33";
        case "orange": return "38;5;208";
        case "dark_orange": return "38;5;130";
        case "cyan": return "36";
        case "light_blue": return "94";
        case "magenta": return "35";
        case "blue": return "34";
        case "gray": return "90";
        default: return "";
    }
}
