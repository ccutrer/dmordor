module mordor.common.streams.handle;

import tango.util.log.Log;
import win32.winbase;
import win32.winnt;

import mordor.common.iomanager;
public import mordor.common.streams.stream;

class HandleStream : Stream
{
public:
    static this()
    {
        _log = Log.lookup("mordor.common.streams.handle");
    }

	this(HANDLE hFile, bool ownHandle = true)
	{
        _log.trace("Creating HandleStream on handle {}", hFile);
		_hFile = hFile;
		_own = ownHandle;
	}
	
	this(IOManager ioManager, HANDLE hFile, bool ownHandle = true)
	{
        _log.trace("Creating HandleStream on handle {} using scheduler {}",
            hFile, ioManager.name);
		_ioManager = ioManager;
		_hFile = hFile;
		_own = ownHandle;
	}
	
	result_t close(CloseType type)
	in
	{
		assert(type == CloseType.BOTH);
	}
	body
	{
		if (_hFile != INVALID_HANDLE_VALUE && _own) {
            _log.trace("Closing handle {}", _hFile);
			CloseHandle(_hFile);
			_hFile = INVALID_HANDLE_VALUE;
		}
		return 0;
	}
	
	bool supportsRead() { return true; }
	bool supportsWrite() { return true; }
    bool supportsSeek() {
        return GetFileType(_hFile) == FILE_TYPE_DISK;
    }
    bool supportsTruncate() { return supportsSeek; }
	
	result_t read(Buffer b, size_t len)
	{
        DWORD read;
        OVERLAPPED* overlapped;
        if (_ioManager !is null) {
            _ioManager.registerEvent(&_readEvent);
            overlapped = &_readEvent.overlapped;
            if (supportsSeek) {
                overlapped.Offset = cast(DWORD)_pos;
                overlapped.OffsetHigh = cast(DWORD)(_pos >> 32);
            }
        }
        void[] buf = b.writeBuf(len);
        _log.trace("Reading {} bytes from handle {}", len, _hFile);
        BOOL ret = ReadFile(_hFile, buf.ptr, buf.length, &read, overlapped);
        if (_ioManager !is null) {
            if (!ret && (GetLastError() == ERROR_HANDLE_EOF ||
                    GetLastError() == ERROR_BROKEN_PIPE)) {
                return 0;
            }
            if (!ret && GetLastError() != ERROR_IO_PENDING) {
                _log.trace("Read from handle {} failed with code {}", _hFile, GetLastError());
                return -1;
            }
            Fiber.yield();
            if (!_readEvent.ret && (_readEvent.lastError == ERROR_HANDLE_EOF ||
                _readEvent.lastError == ERROR_BROKEN_PIPE)) {
                return 0;
            }
            if (!_readEvent.ret) {
                _log.trace("Async read from handle {} failed with code {}", _hFile,
                    _readEvent.lastError);
                return -1;
            }
            if (supportsSeek) {
                _pos = (cast(long)overlapped.Offset | (cast(long)overlapped.OffsetHigh << 32)) +
                    _readEvent.numberOfBytes;
            }
            _log.trace("Read {} bytes from handle {}", _readEvent.numberOfBytes, _hFile);
            b.produce(_readEvent.numberOfBytes);
            return _readEvent.numberOfBytes;            
        }
        if (!ret && GetLastError() == ERROR_BROKEN_PIPE) {
            return 0;
        }
        if (!ret) {
            _log.trace("Sync read from handle {} failed with code {}", _hFile, GetLastError());
            return -1;
        }
        _log.trace("Read {} bytes from handle {}", read, _hFile);
        b.produce(read);
		return read;
	}
	
	result_t write(Buffer b, size_t len)
	{
        DWORD written;
        OVERLAPPED* overlapped;
        if (_ioManager !is null) {
            _ioManager.registerEvent(&_writeEvent);
            overlapped = &_writeEvent.overlapped;
            if (supportsSeek) {
                overlapped.Offset = cast(DWORD)_pos;
                overlapped.OffsetHigh = cast(DWORD)(_pos >> 32);
            }
        }
        void[] buf = b.readBuf(len);
        _log.trace("Writing {} bytes to handle {}", len, _hFile);
        BOOL ret = WriteFile(_hFile, buf.ptr, buf.length, &written, overlapped);
        if (_ioManager !is null) {
            if (!ret && GetLastError() != ERROR_IO_PENDING) {
                _log.trace("Write to handle {} failed with code {}", _hFile, GetLastError());
                return -1;
            }
            Fiber.yield();
            if (!_writeEvent.ret) {
                _log.trace("Async write to handle {} failed with code {}", _hFile, _writeEvent.lastError);
                return -1;
            }
            if (supportsSeek) {
                _pos = (cast(long)overlapped.Offset | (cast(long)overlapped.OffsetHigh << 32)) +
                    _writeEvent.numberOfBytes;
            }
            _log.trace("Wrote {} bytes to handle {}", _writeEvent.numberOfBytes, _hFile);
            return _writeEvent.numberOfBytes;            
        }
        if (!ret) {
            _log.trace("Sync write to handle {} failed with code {}", _hFile, GetLastError());
            return -1;
        }
        _log.trace("Wrote {} bytes to handle {}", written, _hFile);
		return written;
	}

    result_t seek(long offset, Anchor anchor, out long pos)
    {
        if (_ioManager !is null) {
            if (supportsSeek) {
                switch (anchor) {
                    case Anchor.BEGIN:
                        if (offset < 0)
                            return -1;
                        pos = _pos = offset;
                        return 0;
                    case Anchor.CURRENT:
                        if (_pos + offset < 0)
                            return 01;
                        pos = _pos = _pos + offset;
                        return 0;
                    case Anchor.END:
                        result_t result = size(pos);
                        if (result != 0)
                            return result;
                        if (pos + offset < 0)
                            return -1;
                        pos = _pos = pos + offset;
                        return 0;                    
                }
            } else {
                return -1;
            }
        }
        
        BOOL ret = SetFilePointerEx(_hFile, *cast(LARGE_INTEGER*)&offset,
            cast(LARGE_INTEGER*)&pos, cast(DWORD)anchor);
        if (!ret)
            return -1;
        return 0;
    }
    
    result_t truncate(long size)
    {
        long curPos, dummy;
        result_t result = seek(0, Anchor.CURRENT, curPos);
        if (result != 0)
            return result;
        result = seek(size, Anchor.BEGIN, dummy);
        if (result != 0)
            return result;
        BOOL ret = SetEndOfFile(_hFile);
        result = seek(curPos, Anchor.BEGIN, dummy);
        if (result != 0)
            return result;
        if (!ret)
            return -1;
        return 0;
    }
	
private:
	IOManager _ioManager;
    AsyncEvent _readEvent;
    AsyncEvent _writeEvent;
    long _pos;
	HANDLE _hFile;
	bool _own;
    static Logger _log;
}