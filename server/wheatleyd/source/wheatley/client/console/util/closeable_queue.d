module wheatley.client.console.util.closeable_queue;

struct QueuePop(T)
{
    bool found;
    T value;
}

final class CloseableQueue(T)
{
    private T[] items;
    private bool closed;

    void push(T value)
    {
        if (!closed) items ~= value;
    }

    QueuePop!T pop()
    {
        if (!items.length) return QueuePop!T(false, T.init);
        auto value = items[0];
        items = items[1 .. $];
        return QueuePop!T(true, value);
    }

    void close()
    {
        closed = true;
    }

    @property bool closedAndEmpty()
    {
        return closed && !items.length;
    }
}
