#!/usr/bin/env ruby

require 'delegate'
require 'singleton'
require 'tempfile'
require 'ftools'
require 'zlib'
require 'zipfilesystem'

module Enumerable  #:nodoc:all
  def inject(n = 0)
    each { |value| n = yield(n, value) }
    n
  end
end

class Time
  
  #MS-DOS File Date and Time format as used in Interrupt 21H Function 57H:
  # 
  # Register CX, the Time:
  # Bits 0-4  2 second increments (0-29)
  # Bits 5-10 minutes (0-59)
  # bits 11-15 hours (0-24)
  # 
  # Register DX, the Date:
  # Bits 0-4 day (1-31)
  # bits 5-8 month (1-12)
  # bits 9-15 year (four digit year minus 1980)
  
  
  def toBinaryDosDate
    (sec/2) +
      (min  << 5) +
      (hour << 11)
  end

  def toBinaryDosTime
    (day) +
      (month << 5) +
      ((year - 1980) << 9)
  end

  # Dos time is only stored with two seconds accuracy
  def dosEquals(other)
    (year  == other.year   &&
     month == other.month  &&
     day   == other.day    &&
     hour  == other.hour   &&
     min   == other.min &&
     sec/2 == other.sec/2)
  end

  def self.parseBinaryDosFormat(binaryDosDate, binaryDosTime)
    second = 2 * (       0b11111 & binaryDosTime)
    minute = (     0b11111100000 & binaryDosTime) >> 5 
    hour   = (0b1111100000000000 & binaryDosTime) >> 11
    day    = (           0b11111 & binaryDosDate) 
    month  = (       0b111100000 & binaryDosDate) >> 5
    year   = ((0b1111111000000000 & binaryDosDate) >> 9) + 1980
    begin
      return Time.local(year, month, day, hour, minute, second)
    end
  end
end

module Zip
  
  # Implements many of the convenience methods of IO
  # such as gets, getc, readline and readlines 
  # depends on: inputFinished?, produceInput and read
  module AbstractInputStream  
    include Enumerable
    
    def readlines(aSepString = $/)
      retVal = []
      each_line(aSepString) { |line| retVal << line }
      return retVal
    end
    
    def gets(aSepString=$/)
      @outputBuffer ||= ""
      return read if aSepString == nil
      aSepString="#{$/}#{$/}" if aSepString == ""
      
      bufferIndex=0
      while ((matchIndex = @outputBuffer.index(aSepString, bufferIndex)) == nil)
	bufferIndex=@outputBuffer.length
	if inputFinished?
	  return @outputBuffer.length==0 ? nil : flush 
	end
	@outputBuffer << produceInput
      end
      sepIndex=matchIndex + aSepString.length
      return @outputBuffer.slice!(0...sepIndex)
    end
    
    def flush
      @outputBuffer ||= ""
      retVal=@outputBuffer
      @outputBuffer=""
      return retVal
    end
    
    def readline(aSepString = $/)
      retVal = gets(aSepString)
      raise EOFError if retVal == nil
      return retVal
    end
    
    def each_line(aSepString = $/)
      while true
	yield readline
      end
    rescue EOFError
    end
    
    alias_method :each, :each_line
  end


  #relies on <<
  module AbstractOutputStream 
    def write(data)
      self << data
      data.to_s.length
    end


    def print(*params)
      self << params.to_s << $\.to_s
    end

    def printf(aFormatString, *params)
      self << sprintf(aFormatString, *params)
    end

    def putc(anObject)
      self << case anObject
	      when Fixnum then anObject.chr
	      when String then anObject
	      else raise TypeError, "putc: Only Fixnum and String supported"
	      end
      anObject
    end
    
    def puts(*params)
      params << "\n" if params.empty?
      params.flatten.each {
	|element|
	val = element.to_s
	self << val
	self << "\n" unless val[-1,1] == "\n"
      }
    end

  end
  
  
  class ZipInputStream 
    include AbstractInputStream
    
    def initialize(filename, offset = 0)
      @archiveIO = File.open(filename, "rb")
      @archiveIO.seek(offset, IO::SEEK_SET)
      @decompressor = NullDecompressor.instance
      @currentEntry = nil
    end
    
    def close
      @archiveIO.close
    end
    
    def ZipInputStream.open(filename)
      return new(filename) unless block_given?
      
      zio = new(filename)
      yield zio
    ensure
      zio.close if zio
    end

    def getNextEntry
      @archiveIO.seek(@currentEntry.nextHeaderOffset, 
		      IO::SEEK_SET) if @currentEntry
      
      @currentEntry = ZipEntry.readLocalEntry(@archiveIO)
      if (@currentEntry == nil) 
	@decompressor = NullDecompressor.instance
      elsif @currentEntry.compressionMethod == ZipEntry::STORED
	@decompressor = PassThruDecompressor.new(@archiveIO, 
						 @currentEntry.size)
      elsif @currentEntry.compressionMethod == ZipEntry::DEFLATED
	@decompressor = Inflater.new(@archiveIO)
      else
	raise ZipCompressionMethodError,
	  "Unsupported compression method #{@currentEntry.compressionMethod}"
      end
      flush
      return @currentEntry
    end
    
    def read(numberOfBytes = nil)
      @decompressor.read(numberOfBytes)
    end
    protected
    def produceInput
      @decompressor.produceInput
    end
    
    def inputFinished?
      @decompressor.inputFinished?
    end
  end
  
  
  
  class Decompressor  #:nodoc:all
    CHUNK_SIZE=32768
    def initialize(inputStream)
      @inputStream=inputStream
    end
  end
  
  class Inflater < Decompressor  #:nodoc:all
    def initialize(inputStream)
      super
      @zlibInflater = Zlib::Inflate.new(-Zlib::Inflate::MAX_WBITS)
      @outputBuffer=""
      @hasReturnedEmptyString = false
    end
    
    def read(numberOfBytes = nil)
      readEverything = (numberOfBytes == nil)
      while (readEverything || @outputBuffer.length < numberOfBytes)
	break if inputFinished?
	@outputBuffer << produceInput
      end
      return valueWhenFinished if @outputBuffer.length==0 && inputFinished?
      endIndex= numberOfBytes==nil ? @outputBuffer.length : numberOfBytes
      return @outputBuffer.slice!(0...endIndex)
    end
    
    def produceInput
      @zlibInflater.inflate(@inputStream.read(Decompressor::CHUNK_SIZE))
    end
    
    # to be used with produceInput, not read (as read may still have more data cached)
    def inputFinished?
      @zlibInflater.finished?
    end

    private
    def valueWhenFinished   # mimic behaviour of ruby File object.
      return nil if @hasReturnedEmptyString
      @hasReturnedEmptyString=true
      return ""
    end
  end
  
  class PassThruDecompressor < Decompressor  #:nodoc:all
    def initialize(inputStream, charsToRead)
      super inputStream
      @charsToRead = charsToRead
      @readSoFar = 0
      @isFirst=true
    end
    
    def read(numberOfBytes = nil)
      if inputFinished?
	isFirstVal=@isFirst
	@isFirst=false
	return "" if isFirstVal
	return nil
      end
      
      if (numberOfBytes == nil || @readSoFar+numberOfBytes > @charsToRead)
	numberOfBytes = @charsToRead-@readSoFar
      end
      @readSoFar += numberOfBytes
      @inputStream.read(numberOfBytes)
    end
    
    def produceInput
      read(Decompressor::CHUNK_SIZE)
    end
    
    def inputFinished?
      (@readSoFar >= @charsToRead)
    end
  end
  
  class NullDecompressor  #:nodoc:all
    include Singleton
    def read(numberOfBytes = nil)
      nil
    end
    
    def produceInput
      nil
    end
    
    def inputFinished?
      true
    end
  end
  
  class NullInputStream < NullDecompressor  #:nodoc:all
    include AbstractInputStream
  end
  
  class ZipEntry
    STORED = 0
    DEFLATED = 8
    
    attr_accessor  :comment, :compressedSize, :crc, :extra, :compressionMethod, 
      :name, :size, :localHeaderOffset, :time
    
    alias :mtime :time

    def initialize(zipfile = "", name = "", comment = "", extra = "", 
		   compressedSize = 0, crc = 0, 
		   compressionMethod = ZipEntry::DEFLATED, size = 0,
		   time  = Time.now)
      @localHeaderOffset = 0
      @zipfile, @comment, @compressedSize, @crc, @extra, @compressionMethod, 
	@name, @size = zipfile, comment, compressedSize, crc, 
	extra, compressionMethod, name, size
      @time = time
    end
    
    def directory?
      return (%r{\/$} =~ @name) != nil
    end
    alias :isDirectory :directory?

    def file?
      ! directory?
    end

    def localEntryOffset  #:nodoc:all
      localHeaderOffset + localHeaderSize
    end
    
    def localHeaderSize  #:nodoc:all
      LOCAL_ENTRY_STATIC_HEADER_LENGTH + (@name ?  @name.size : 0) + (@extra ? @extra.size : 0)
    end

    def cdirHeaderSize  #:nodoc:all
      CDIR_ENTRY_STATIC_HEADER_LENGTH  + (@name ?  @name.size : 0) + 
	(@extra ? @extra.size : 0) + (@comment ? @comment.size : 0)
    end
    
    def nextHeaderOffset  #:nodoc:all
      localEntryOffset + self.compressedSize
    end
    
    def to_s
      @name
    end
    
    protected
    
    def ZipEntry.readZipShort(io)
      io.read(2).unpack('v')[0]
    end
    
    def ZipEntry.readZipLong(io)
      io.read(4).unpack('V')[0]
    end
    public
    
    LOCAL_ENTRY_SIGNATURE = 0x04034b50
    LOCAL_ENTRY_STATIC_HEADER_LENGTH = 30
    
    def readLocalEntry(io)  #:nodoc:all
      @localHeaderOffset = io.tell
      staticSizedFieldsBuf = io.read(LOCAL_ENTRY_STATIC_HEADER_LENGTH)
      unless (staticSizedFieldsBuf.size==LOCAL_ENTRY_STATIC_HEADER_LENGTH)
	raise ZipError, "Premature end of file. Not enough data for zip entry local header"
      end
      
      localHeader       ,
	@version          ,
	@gpFlags          ,
	@compressionMethod,
	lastModTime       ,
	lastModDate       ,
	@crc              ,
	@compressedSize   ,
	@size             ,
	nameLength        ,
	extraLength       = staticSizedFieldsBuf.unpack('VvvvvvVVVvv') 

      unless (localHeader == LOCAL_ENTRY_SIGNATURE)
	raise ZipError, "Zip local header magic not found at location '#{localHeaderOffset}'"
      end
      setTime(lastModDate, lastModTime)
      
      @name              = io.read(nameLength)
      @extra             = io.read(extraLength)
      unless (@extra && @extra.length == extraLength)
	raise ZipError, "Truncated local zip entry header"
      end
    end
    
    def ZipEntry.readLocalEntry(io)
      entry = new(io.path)
      entry.readLocalEntry(io)
      return entry
    rescue ZipError
      return nil
    end
  
    def writeLocalEntry(io)   #:nodoc:all
      @localHeaderOffset = io.tell
      
      io << 
	[LOCAL_ENTRY_SIGNATURE    ,
	0                         , # @version                  ,
	0                         , # @gpFlags                  ,
	@compressionMethod        ,
	@time.toBinaryDosDate     , # @lastModTime              ,
	@time.toBinaryDosTime     , # @lastModDate              ,
	@crc                      ,
	@compressedSize           ,
	@size                     ,
	@name ? @name.length   : 0,
	@extra? @extra.length : 0 ].pack('VvvvvvVVVvv')
      io << @name
      io << @extra
    end
    
    CENTRAL_DIRECTORY_ENTRY_SIGNATURE = 0x02014b50
    CDIR_ENTRY_STATIC_HEADER_LENGTH = 46
    
    def readCDirEntry(io)  #:nodoc:all
      staticSizedFieldsBuf = io.read(CDIR_ENTRY_STATIC_HEADER_LENGTH)
      unless (staticSizedFieldsBuf.size == CDIR_ENTRY_STATIC_HEADER_LENGTH)
	raise ZipError, "Premature end of file. Not enough data for zip cdir entry header"
      end
      
      cdirSignature          ,
	@version               ,
	@versionNeededToExtract,
	@gpFlags               ,
	@compressionMethod     ,
	lastModTime            ,
	lastModDate            ,
	@crc                   ,
	@compressedSize        ,
	@size                  ,
	nameLength             ,
	extraLength            ,
	commentLength          ,
	diskNumberStart        ,
	@internalFileAttributes,
	@externalFileAttributes,
	@localHeaderOffset     ,
	@name                  ,
	@extra                 ,
	@comment               = staticSizedFieldsBuf.unpack('VvvvvvvVVVvvvvvVV')

      unless (cdirSignature == CENTRAL_DIRECTORY_ENTRY_SIGNATURE)
	raise ZipError, "Zip local header magic not found at location '#{localHeaderOffset}'"
      end
      setTime(lastModDate, lastModTime)
      
      @name                  = io.read(nameLength)
      @extra                 = io.read(extraLength)
      @comment               = io.read(commentLength)
      unless (@comment && @comment.length == commentLength)
	raise ZipError, "Truncated cdir zip entry header"
      end
    end
    
    def ZipEntry.readCDirEntry(io)  #:nodoc:all
      entry = new(io.path)
      entry.readCDirEntry(io)
      return entry
    rescue ZipError
      return nil
    end


    def writeCDirEntry(io)  #:nodoc:all
      io << 
	[CENTRAL_DIRECTORY_ENTRY_SIGNATURE,
	0                                 , # @version                          ,
	0                                 , # @versionNeededToExtract           ,
	0                                 , # @gpFlags                          ,
	@compressionMethod                ,
        @time.toBinaryDosDate             , # @lastModTime                      ,
	@time.toBinaryDosTime             , # @lastModDate                      ,
	@crc                              ,
	@compressedSize                   ,
	@size                             ,
	@name  ?  @name.length  : 0       ,
	@extra ? @extra.length : 0        ,
	@comment ? comment.length : 0     ,
	0                                 , # disk number start
	0                                 , # @internalFileAttributes           ,
	0                                 , # @externalFileAttributes           ,
	@localHeaderOffset                ,
	@name                             ,
	@extra                            ,
	@comment                          ].pack('VvvvvvvVVVvvvvvVV')

      io << @name
      io << @extra
      io << @comment
    end
    
    def == (other)
      return false unless other.kind_of?(ZipEntry)

      # Compares contents of local entry and exposed fields
      (@compressionMethod == other.compressionMethod &&
       @crc               == other.crc		     &&
       @compressedSize    == other.compressedSize    &&
       @size              == other.size	             &&
       @name              == other.name	             &&
       @extra             == other.extra             &&
       @time.dosEquals(other.time))
    end

    def getInputStream
      zis = ZipInputStream.new(@zipfile, localHeaderOffset)
      zis.getNextEntry
      if block_given?
	begin
	  return yield zis
	ensure
	  zis.close
	end
      else
	return zis
      end
    end


    def writeToZipOutputStream(aZipOutputStream)  #:nodoc:all
      aZipOutputStream.putNextEntry(self.dup)
      aZipOutputStream << getRawInputStream { 
	|is| 
	is.seek(localEntryOffset, IO::SEEK_SET)
	is.read(compressedSize)
      }
    end

    private
    def getRawInputStream(&aProc)
      File.open(@zipfile, "rb", &aProc)
    end

    def setTime(binaryDosDate, binaryDosTime)
      @time = Time.parseBinaryDosFormat(binaryDosDate, binaryDosTime)
    rescue ArgumentError
      puts "Invalid date/time in zip entry"
    end
  end


  class ZipOutputStream
    include AbstractOutputStream

    attr_accessor :comment

    def initialize(fileName)
      @fileName = fileName
      @outputStream = File.new(@fileName, "wb")
      @entries = []
      @compressor = NullCompressor.instance
      @closed = false
      @currentEntry = nil
      @comment = nil
    end

    def ZipOutputStream.open(fileName)
      return new(fileName) unless block_given?
      zos = new(fileName)
      yield zos
    ensure
      zos.close if zos
    end

    def close
      return if @closed
      finalizeCurrentEntry
      updateLocalHeaders
      writeCentralDirectory
      @outputStream.close
      @closed = true
    end

    def putNextEntry(entry, level = Zlib::DEFAULT_COMPRESSION)
      raise ZipError, "zip stream is closed" if @closed
      newEntry = entry.kind_of?(ZipEntry) ? entry : ZipEntry.new(@fileName, entry.to_s)
      initNextEntry(newEntry)
      @currentEntry=newEntry
    end

    private
    def finalizeCurrentEntry
      return unless @currentEntry
      finish
      @currentEntry.compressedSize = @outputStream.tell - @currentEntry.localHeaderOffset - 
	@currentEntry.localHeaderSize
      @currentEntry.size = @compressor.size
      @currentEntry.crc = @compressor.crc
      @currentEntry = nil
      @compressor = NullCompressor.instance
    end
    
    def initNextEntry(entry, level = Zlib::DEFAULT_COMPRESSION)
      finalizeCurrentEntry
      @entries << entry
      entry.writeLocalEntry(@outputStream)
      @compressor = getCompressor(entry, level)
    end

    def getCompressor(entry, level)
      case entry.compressionMethod
	when ZipEntry::DEFLATED then Deflater.new(@outputStream, level)
	when ZipEntry::STORED   then PassThruCompressor.new(@outputStream)
      else raise ZipCompressionMethodError, 
	  "Invalid compression method: '#{entry.compressionMethod}'"
      end
    end

    def updateLocalHeaders
      pos = @outputStream.tell
      @entries.each {
	|entry|
	@outputStream.pos = entry.localHeaderOffset
	entry.writeLocalEntry(@outputStream)
      }
      @outputStream.pos = pos
    end

    def writeCentralDirectory
      cdir = ZipCentralDirectory.new(@entries, @comment)
      cdir.writeToStream(@outputStream)
    end

    protected

    def finish
      @compressor.finish
    end

    public
    def << (data)
      @compressor << data
    end
  end
  
  
  class Compressor #:nodoc:all
    def finish
    end
  end
  
  class PassThruCompressor < Compressor #:nodoc:all
    def initialize(outputStream)
      @outputStream = outputStream
      @crc = Zlib::crc32
      @size = 0
    end
    
    def << (data)
      val = data.to_s
      @crc = Zlib::crc32(val, @crc)
      @size += val.size
      @outputStream << val
    end

    attr_reader :size, :crc
  end

  class NullCompressor < Compressor #:nodoc:all
    include Singleton

    def << (data)
      raise IOError, "closed stream"
    end

    attr_reader :size, :compressedSize
  end

  class Deflater < Compressor #:nodoc:all
    def initialize(outputStream, level = Zlib::DEFAULT_COMPRESSION)
      @outputStream = outputStream
      @zlibDeflater = Zlib::Deflate.new(level, -Zlib::Deflate::MAX_WBITS)
      @size = 0
      @crc = Zlib::crc32
    end
    
    def << (data)
      val = data.to_s
      @crc = Zlib::crc32(val, @crc)
      @size += val.size
      @outputStream << @zlibDeflater.deflate(data)
    end

    def finish
      until @zlibDeflater.finished?
	@outputStream << @zlibDeflater.finish
      end
    end

    attr_reader :size, :crc
  end
  
  class ZipCentralDirectory #:nodoc:all
    include Enumerable
    
    END_OF_CENTRAL_DIRECTORY_SIGNATURE = 0x06054b50
    MAX_END_OF_CENTRAL_DIRECTORY_STRUCTURE_SIZE = 65536 + 18
    STATIC_EOCD_SIZE = 22

    attr_reader :size, :comment, :entries
    
    def initialize(entries = [], comment = "")
      @entries = entries
      @comment = comment
    end

    def writeToStream(io)
      offset = io.tell
      @entries.each { |entry| entry.writeCDirEntry(io) }
      writeEOCD(io, offset)
    end

    def writeEOCD(io, offset)
      io <<
	[END_OF_CENTRAL_DIRECTORY_SIGNATURE,
        0                                  , # @numberOfThisDisk
	0                                  , # @numberOfDiskWithStartOfCDir
	@entries? @entries.size : 0        ,
	@entries? @entries.size : 0        ,
	cdirSize                           ,
	offset                             ,
	@comment ? @comment.length : 0     ].pack('VvvvvVVv')
      io << @comment
    end
    private :writeEOCD

    def cdirSize
      # does not include eocd
      @entries.inject { |value, entry| entry.cdirHeaderSize + value }
    end
    private :cdirSize

    def readEOCD(io)
      buf = getEOCD(io)
      @numberOfThisDisk                     = ZipEntry::readZipShort(buf)
      @numberOfDiskWithStartOfCDir          = ZipEntry::readZipShort(buf)
      @totalNumberOfEntriesInCDirOnThisDisk = ZipEntry::readZipShort(buf)
      @size                                 = ZipEntry::readZipShort(buf)
      @sizeInBytes                          = ZipEntry::readZipLong(buf)
      @cdirOffset                           = ZipEntry::readZipLong(buf)
      commentLength                         = ZipEntry::readZipShort(buf)
      @comment                              = buf.read(commentLength)
      raise ZipError, "Zip consistency problem while reading eocd structure" unless buf.size == 0
    end
    
    def readCentralDirectoryEntries(io)
      begin
	io.seek(@cdirOffset, IO::SEEK_SET)
      rescue Errno::EINVAL
	raise ZipError, "Zip consistency problem while reading central directory entry"
      end
      @entries = []
      @size.times {
	@entries << ZipEntry.readCDirEntry(io)
      }
    end
    
    def readFromStream(io)
      readEOCD(io)
      readCentralDirectoryEntries(io)
    end
    
    def getEOCD(io)
      begin
	io.seek(-MAX_END_OF_CENTRAL_DIRECTORY_STRUCTURE_SIZE, IO::SEEK_END)
      rescue Errno::EINVAL
	io.seek(0, IO::SEEK_SET)
      end
      buf = io.read
      sigIndex = buf.rindex([END_OF_CENTRAL_DIRECTORY_SIGNATURE].pack('V'))
      raise ZipError, "Zip end of central directory signature not found" unless sigIndex
      buf=buf.slice!((sigIndex+4)...(buf.size))
      def buf.read(count)
	slice!(0, count)
      end
      return buf
    end
    
    def each(&proc)
      @entries.each(&proc)
    end

    def ZipCentralDirectory.readFromStream(io)
      cdir  = new
      cdir.readFromStream(io)
      return cdir
    rescue ZipError
      return nil
    end

    def == (other)
      return false unless other.kind_of?(ZipCentralDirectory)
      @entries == other.entries && comment == other.comment
    end
  end
  
  
  class ZipError < StandardError ; end

  class ZipEntryExistsError            < ZipError; end
  class ZipDestinationFileExistsError  < ZipError; end
  class ZipCompressionMethodError      < ZipError; end

  class ZipFile < ZipCentralDirectory
    CREATE = 1

    attr_reader :name

    def initialize(fileName, create = nil)
      @name = fileName
      @comment = ""
      if (File.exists?(fileName))
	File.open(name, "rb") { |f| readFromStream(f) }
      elsif (create == ZipFile::CREATE)
	@entries = []
      else
	raise ZipError, "File #{fileName} not found"
      end
      @create = create
      @storedEntries = @entries.map{ |e| e.dup }
    end
    
    def ZipFile.open(fileName, create = nil)
      zf = ZipFile.new(fileName, create)
      if block_given?
	begin
	  yield zf
	ensure
	  zf.close
	end
      else
	zf
      end
    end

    attr_accessor :comment

    def ZipFile.foreach(aZipFileName, &block)
      ZipFile.open(aZipFileName) {
	|zipFile|
	zipFile.each(&block)
      }
    end
    
    def getInputStream(entry, &aProc)
      getEntry(entry).getInputStream(&aProc)
    end
    
    def to_s
      @name
    end

    def fileSystem
      @fileSystem ||= ZipFileSystem.new(self)
    end

    def add(entry, srcPath, &continueOnExistsProc)
      continueOnExistsProc ||= proc { false }
      checkEntryExists(entry, continueOnExistsProc, "add")
      newEntry = entry.kind_of?(ZipEntry) ? entry : ZipEntry.new(@name, entry.to_s)
      if isDirectory(newEntry, srcPath)
	@entries << ZipStreamableDirectory.new(newEntry)
      else
	@entries << ZipStreamableFile.new(newEntry, srcPath)
      end
    end
    
    def remove(entry)
      @entries.delete(getEntry(entry))
    end
    
    def rename(entry, newName, &continueOnExistsProc)
      foundEntry = getEntry(entry)
      checkEntryExists(newName, continueOnExistsProc, "rename")
      foundEntry.name=newName
    end

    def replace(entry, srcPath)
      checkFile(srcPath)
      add(remove(entry), srcPath)
    end
    
    def extract(entry, destPath, &onExistsProc)
      onExistsProc ||= proc { false }
      foundEntry = getEntry(entry)
      if foundEntry.isDirectory
	createDirectory(foundEntry, destPath, &onExistsProc)
      else
	writeFile(destPath, onExistsProc) { 
	  |os|
	  foundEntry.getInputStream { |is| os << is.read }
	}
      end
    end
    
    def commit
      return if ! commitRequired?
      onSuccessReplace(name) {
	|tmpFile|
	ZipOutputStream.open(tmpFile) {
	  |zos|

	  @entries.each { |e| e.writeToZipOutputStream(zos) }
	  zos.comment = comment
	}
	true
      }
      initialize(name)
    end
    
    def close
      commit
    end

    def commitRequired?
      return entries != @storedEntries || @create == ZipFile::CREATE
    end

    def findEntry(entry)
      @entries.detect { 
	|e| 
	e.name.sub(/\/$/, "") == entry.to_s.sub(/\/$/, "")
      }
    end
    
    def getEntry(entry)
      selectedEntry = findEntry(entry)
      unless selectedEntry
	raise Errno::ENOENT, 
	  "No matching entry found in zip file '#{@name}' for '#{entry}'"
      end
      return selectedEntry
    end

    private

    def createDirectory(entry, destPath)
      if File.directory? destPath
	return
      elsif File.exists? destPath
	if block_given? && yield(entry, destPath)
	  File.rm_f destPath
	else
	  raise ZipDestinationFileExistsError,
	    "Cannot create directory '#{destPath}'. "+
	    "A file already exists with that name"
	end
      end
      Dir.mkdir destPath
    end

    def isDirectory(newEntry, srcPath)
      srcPathIsDirectory = File.directory?(srcPath)
      if newEntry.isDirectory && ! srcPathIsDirectory
	raise ArgumentError,
	  "entry name '#{newEntry}' indicates directory entry, but "+
	  "'#{srcPath}' is not a directory"
      elsif ! newEntry.isDirectory && srcPathIsDirectory
	newEntry.name += "/"
      end
      return newEntry.isDirectory && srcPathIsDirectory
    end

    def checkEntryExists(entryName, continueOnExistsProc, procedureName)
      continueOnExistsProc ||= proc { false }
      if @entries.detect { |e| e.name == entryName }
	if continueOnExistsProc.call
	  remove getEntry(entryName)
	else
	  raise ZipEntryExistsError, 
	    procedureName+" failed. Entry #{entryName} already exists"
	end
      end
    end

    def writeFile(destPath, continueOnExistsProc = proc { false }, &writeFileProc)
      if File.exists?(destPath) && ! continueOnExistsProc.call
	raise ZipDestinationFileExistsError,
	  "Destination '#{destPath}' already exists"
      end
      File.open(destPath, "wb", &writeFileProc)
    end
    
    def checkFile(path)
      unless File.readable? path
	raise Errno::ENOENT, 
	  "'#{path}' does not exist or cannot be opened reading"
      end
    end
    
    def onSuccessReplace(aFilename)
      tmpfile = getTempfile
      tmpFilename = tmpfile.path
      tmpfile.close
      if yield tmpFilename
	File.move(tmpFilename, name)
      end
    end
    
    def getTempfile
      Tempfile.new(File.basename(name), File.dirname(name)).binmode
    end
    
  end

  class ZipStreamableFile < DelegateClass(ZipEntry) #:nodoc:all
    def initialize(entry, filepath)
      super(entry)
      @filepath = filepath
    end

    def getInputStream(&aProc)
      File.open(@filepath, "rb", &aProc)
    end
    
    def writeToZipOutputStream(aZipOutputStream)
      aZipOutputStream.putNextEntry(self)
      aZipOutputStream << getInputStream { |is| is.read }
    end
  end

  class ZipStreamableDirectory < DelegateClass(ZipEntry) #:nodoc:all
    def initialize(entry)
      super(entry)
    end

    def getInputStream(&aProc)
      return yield NullInputStream.instance if block_given?
      NullInputStream.instance
    end
    
    def writeToZipOutputStream(aZipOutputStream)
      aZipOutputStream.putNextEntry(self)
    end
  end

end # Zip namespace module



# Copyright (C) 2002 Thomas Sondergaard
# rubyzip is free software; you can redistribute it and/or
# modify it under the terms of the ruby license.
