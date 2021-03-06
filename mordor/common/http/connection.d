module mordor.common.http.connection;

import mordor.common.http.chunked;
import mordor.common.http.parser;
import mordor.common.scheduler;
import mordor.common.streams.buffered;
import mordor.common.streams.duplex;
import mordor.common.streams.gzip;
import mordor.common.streams.limited;
import mordor.common.streams.notify;
import mordor.common.streams.singleplex;
import mordor.common.streams.zlib;

package abstract class Connection
{
protected:
    this(Stream stream)
    in
    {
        assert(stream !is null);
        assert(stream.supportsRead);
        assert(stream.supportsWrite);
    }
    body
    {
        _readStream = cast(BufferedStream)stream;
        if (_readStream is null) {
            _readStream = new BufferedStream(new SingleplexStream(stream, SingleplexStream.Type.READ, false));
        }
        _readStream.allowPartialReads = true;
        _writeStream = new SingleplexStream(stream, SingleplexStream.Type.WRITE, false);
        _stream = new DuplexStream(_readStream, stream);
    }
    
    static bool hasMessageBody(GeneralHeaders general, EntityHeaders entity, Method method, Status status)
    {
        if (status == Status.init) {
            switch (method) {
                case Method.GET:
                case Method.HEAD:
                case Method.TRACE:
                    return false;
                default:
                    break;
            }
            if (entity.contentLength != ~0 && entity.contentLength != 0)
                return true;
            foreach(tc; general.transferEncoding) {
                if (tc.value != "identity")
                    return true;
            }
            return false;
        } else {
            switch (method) {
                case Method.HEAD:
                case Method.TRACE:
                    return false;
                default:
                    break;
            }
            if (cast(int)status >= 100 && cast(int)status <= 199 ||
                cast(int)status == 204 ||
                cast(int)status == 304 ||
                method == Method.HEAD) {
                return false;
            }
            foreach(tc; general.transferEncoding) {
                if (tc.value != "identity")
                    return true;
            }
            // TODO: if (entity.contentType.major == "multipart") return true;
            if (entity.contentLength == 0)
                return false;
            return true;
        }
    }

    Stream getStream(GeneralHeaders general, EntityHeaders entity, Method method, Status status, void delegate() notifyOnEof, bool forRead)
    in
    {
        assert(hasMessageBody(general, entity, method, status));
    }
    body
    {
        Stream stream;
        if (forRead)
            stream = _readStream;
        else
            stream = _writeStream;
        Stream baseStream = stream;
        foreach (tc; general.transferEncoding) {
            switch (tc.value) {
                case "chunked":
                    stream = new ChunkedStream(stream);
                    auto notify = new NotifyStream(stream);
                    notify.notifyOnEof = notifyOnEof;
                    stream = notify;
                    break;
                case "deflate":
                    stream = new ZlibStream(stream);
                    break;
                case "gzip":
                case "x-gzip":
                    stream = new GzipStream(stream);
                    break;
                case "identity":
                case "compress":
                case "x-compress":
                    assert(false);
            }
        }
        if (stream !is baseStream) {
            return stream;
        } else if (entity.contentLength != ~0) {
            auto notify = new NotifyStream(stream, false);
            notify.notifyOnClose = notifyOnEof;
            auto limited = new LimitedStream(notify, entity.contentLength);
            limited.closeOnEof = true;
            return limited;
        // TODO: else if (entity.contentType.major == "multipart") return stream;
        } else {
            // Delimited by closing the connection
            assert(general.connection !is null && general.connection.find("close") != general.connection.end);
            auto notify = new NotifyStream(stream, false);
            notify.notifyOnEof = notifyOnEof;
            return notify;
        }
    }

protected:
    BufferedStream _readStream;
    Stream _stream, _writeStream;
}
