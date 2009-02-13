module mordor.common.streams.streamtostream;

import tango.math.Math;

import mordor.common.config;
import mordor.common.scheduler;
import mordor.common.streams.stream;

private ConfigVar!(size_t) _chunkSize;

static this()
{
    _chunkSize =
    Config.lookup!(size_t)("stream.streamtostream.chunksize",
        64u * 1024u, "Size of buffers to use when transferring streams");
}

result_t streamToStream(Stream src, Stream dst, out long transferred, long toTransfer)
in
{
    assert(src !is null);
    assert(src.supportsRead);
    assert(dst !is null);
    assert(dst.supportsWrite);
    assert(toTransfer >= 0L || toTransfer == -1L);
}
body
{
    Buffer buf1 = new Buffer, buf2 = new Buffer;
    Buffer* readBuffer, writeBuffer;
    result_t readResult, writeResult;
    size_t chunkSize = _chunkSize.val;
    size_t todo;
    
    void read()
    {
        todo = chunkSize;
        if (toTransfer != -1L && toTransfer < todo)
            todo = toTransfer;
        readResult = src.read(*readBuffer, todo);
        if (readResult > 0) {
            toTransfer -= readResult;
        }
    }
    
    void write()
    {
        while(writeBuffer.readAvailable > 0) {
            writeResult = dst.write(*writeBuffer, writeBuffer.readAvailable);
            if (writeResult == 0)
                writeResult = -1;
            if (writeResult < 0)
                break;
            writeBuffer.consume(writeResult);
            transferred += writeResult;
        }
    }
    
    readBuffer = &buf1;
    read();
    if (readResult == 0 && toTransfer != -1L)
        readResult = -1;
    if (readResult < 0)
        return readResult;
    if (readResult == 0)
        return 0;    
    
    while (toTransfer > 0  || toTransfer == -1L) {
        writeBuffer = readBuffer;
        if (readBuffer == &buf1)
            readBuffer = &buf2;
        else
            readBuffer = &buf1;
        parallel_do(&read, &write);
        if (readResult == 0 && toTransfer != -1L)
            readResult = -1;
        if (readResult < 0)
            return readResult;
        if (writeResult < 0)
            return writeResult;
        if (readResult == 0)
            return 0;
    }
    writeBuffer = readBuffer;
    write();
    if (writeResult < 0)
        return writeResult;
    return 0;
}

result_t streamToStream(Stream src, Stream dst)
{
    long transferred;
    return streamToStream(src, dst, transferred, -1L);
}

result_t streamToStream(Stream src, Stream dst, out long transferred)
{
    return streamToStream(src, dst, transferred, -1L);
}