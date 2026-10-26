/* This code is subject to the terms of the Mozilla Public License, v.2.0. http://mozilla.org/MPL/2.0/. */
#include "cimbar_recv_js.h"

#include "cimb_translator/Config.h"
#include "compression/zstd_header_check.h"
#include "encoder/Decoder.h"
#include "encoder/escrow_buffer_writer.h"
#include "extractor/Extractor.h"
#include "fountain/fountain_decoder_sink.h"
#include "serialize/str_join.h"
#include "util/File.h"
#include "util/Timer.h"

#include <opencv2/opencv.hpp>

#include <algorithm>
#include <filesystem>
#include <map>
#include <memory>


namespace {
	// for decode
	std::shared_ptr<fountain_decoder_sink> _sink;

	// for decompress
	// we support only one decompress at a time!
	uint32_t _decId = 0;
	std::vector<uchar> _reassembled;
	std::unique_ptr<cimbar::zstd_decompressor<std::stringstream>> _dec;

	std::string _reporting;
	cv::Mat _debugFrame;

	TimeAccumulator _tScanExtract;
	TimeAccumulator _tImgDecode;

	// settings
	int _modeVal = 68;

	// Config::active_conf() is thread_local, but callers (e.g. iOS GCD queues)
	// do not guarantee a stable thread. Track the last mode applied on *this*
	// thread and re-sync Config before any decode work. This keeps non-default
	// modes correct across thread migration without resetting the sink.
	thread_local int _threadModeVal = 0;

	void sync_thread_config()
	{
		if (_threadModeVal != _modeVal)
		{
			cimbar::Config::update(_modeVal);
			_threadModeVal = _modeVal;
		}
	}

	// Decoder construction decodes + hashes all symbol tiles -- far too heavy
	// to do per frame. Cache one per mode, so mode autodetect (which cycles
	// modes frame by frame) doesn't rebuild it. Serial use only (single decode queue).
	std::map<int, std::unique_ptr<Decoder>> _decoders;

	Decoder& get_decoder()
	{
		std::unique_ptr<Decoder>& dec = _decoders[_modeVal];
		if (!dec)
			dec = std::make_unique<Decoder>();
		return *dec;
	}

	// set up stateful decompressor
	// for api simplicity, this is coupled to recover_contents()
	// ... but we *could* split them up
	int init_decompress(uint32_t id)
	{
		if (id != _decId)
			return -11;
		if (_dec)
			_dec.reset();
		_dec = std::make_unique<cimbar::zstd_decompressor<std::stringstream>>();
		if (!_dec)
			return -12;
		// init fails when the underlying ZSTD_DStream couldn't be created
		// (e.g. allocation failure) -- ignoring it would make decompress_read
		// report a clean EOF (0) and silently produce an empty file
		if (!_dec->init_decompress(reinterpret_cast<char*>(_reassembled.data()), _reassembled.size()))
			return -16;
		return 0;
	}

	// recovers file contents into _reassembled, and sets _decId = id if so.
	// if the contents cannot be recovered, amounts to a no-op with error
	int recover_contents(uint32_t id)
	{
		if (id != _decId)
		{
			if (!_sink)
				return -1;
			if (_sink->is_done(id))
				return -2; // it's gone man

			// recover into a scratch buffer and commit only on success:
			// resizing _reassembled before validating would leave _dec's
			// view dangling (use-after-free) for the still-current _decId
			std::vector<uchar> next(cimbard_get_filesize(id));
			if (!_sink->recover(id, next.data(), next.size()))
				return -3;
			_reassembled = std::move(next);
			_decId = id;

			int res = init_decompress(id);
			if (res < 0)
				return res;
		}
		if (_reassembled.empty())
			return -5;

		return 0;
	}

	unsigned fountain_chunks_per_frame()
	{
		return cimbar::Config::fountain_chunks_per_frame(
			cimbar::Config::bits_per_cell()
		);
	}

	unsigned fountain_chunk_size()
	{
		return cimbar::Config::fountain_chunk_size();
	}

	cv::UMat get_rgb(void* imgdata, int width, int height, int type)
	{
		cv::UMat img;
		switch (type)
		{
			case 12:
			{
				img = cv::Mat(height * 3/2, width, CV_8UC1, imgdata).getUMat(cv::ACCESS_RW).clone();
				cv::cvtColor(img, img, cv::COLOR_YUV2RGB_NV12); // 12 or 21 :hmm:
				return img;
			}
			case 420:
			{
				img = cv::Mat(height * 3/2, width, CV_8UC1, imgdata).getUMat(cv::ACCESS_RW).clone();
				cv::cvtColor(img, img, cv::COLOR_YUV420p2RGB);
				return img;
			}
			default:
				break;
		}

		int cvtype = type==4? CV_8UC4 : CV_8UC3;
		img = cv::Mat(height, width, cvtype, imgdata).getUMat(cv::ACCESS_RW).clone();
		if (type == 4)
			cv::cvtColor(img, img, cv::COLOR_RGBA2RGB);
		return img;
	}
}

extern "C" {

unsigned cimbard_get_report(uchar* buff, unsigned maxlen)
{
	int len = std::min<unsigned>(_reporting.size(), maxlen);
	if (len == 0)
		return 0;
	std::copy(_reporting.data(), _reporting.data()+len, buff);
	return len;
}

unsigned cimbard_get_debug(uchar* buff, unsigned maxlen)
{
	int len = std::min<unsigned>(_debugFrame.dims*_debugFrame.cols*_debugFrame.rows, maxlen);
	if (len == 0)
		return 0;
	std::copy(_debugFrame.data, _debugFrame.data+len, buff);
	return len;
}

int cimbard_get_bufsize()
{
	sync_thread_config();
	return fountain_chunks_per_frame() * fountain_chunk_size();
}

int cimbard_scan_extract_decode(const uchar* imgdata, unsigned imgw, unsigned imgh, int format, uchar* bufspace, unsigned bufsize)
{
	sync_thread_config();
	if (format <= 0)
		format = 3;
	if (imgw == 0 or imgh == 0)
		return -1;

	unsigned chunksPerFrame = fountain_chunks_per_frame();
	unsigned chunkSize = fountain_chunk_size();
	// early bail if bufsize doesn't match config params (fountain chunk size * count)
	if (bufsize < chunkSize * chunksPerFrame)
		return -2;

	// interface to take the aligned output buffers of chunkSize and dump them into bufspace
	escrow_buffer_writer ebw(bufspace, chunksPerFrame, chunkSize);
	Extractor ext;
	Decoder& dec = get_decoder();

	cv::UMat img = get_rgb((void*)imgdata, imgw, imgh, format);
#ifndef CIMBARD_NO_DEBUG
	_debugFrame = img.getMat(cv::ACCESS_READ).clone();
#endif

	_reporting = fmt::format("sce: {}, imgdec: {}", _tScanExtract.avg(), _tImgDecode.avg());

	bool shouldPreprocess = true;
	{
		Timer t(_tScanExtract);
		int res = ext.extract(img, img);
		if (!res)
			return -3;
		else if (res == Extractor::NEEDS_SHARPEN)
			shouldPreprocess = true;
	}

	// decode
	int bytes = 0;
	{
		Timer t(_tImgDecode);
		dec.decode_fountain(img, ebw, shouldPreprocess);
	}
	_reporting = fmt::format("sce: {}, imgdec: {}, decoded {} bytes!!! {}", _tScanExtract.avg(), _tImgDecode.avg(), bytes, ebw.buffers_in_use() * chunkSize);
	return ebw.buffers_in_use() * chunkSize;
}

// returns id of final file (can be used to get size of `finish_copy`'s buffer) if complete, 0 if success, -1 on error
int64_t cimbard_fountain_decode(const unsigned char* buffer, unsigned size)
{
	sync_thread_config();
	unsigned chunkSize = fountain_chunk_size();
	if (!_sink) // lazy-create the sink on first run
		_sink = std::make_shared<fountain_decoder_sink>(chunkSize);

	if (size == 0 or size % chunkSize != 0)
		return -5;

	int64_t res = 0;
	for (unsigned i = 0; i < size && res == 0; i+=chunkSize)
	{
		/*std::cout << fmt::format("buff {} of {} -- {},{},{},{},{},{}", i, size, (unsigned)buffer[0+i], (unsigned)buffer[1+i],
				(unsigned)buffer[2+i], (unsigned)buffer[3+i], (unsigned)buffer[4+i], (unsigned)buffer[5+i]) << std::endl;*/
		res = _sink->decode_frame(reinterpret_cast<const char*>(buffer+i), chunkSize);
	}

#ifndef CIMBARD_NO_DEBUG
	std::cout << "fountain decode res is " << res << std::endl;
#endif

	// res will be the file id on completion, 0 otherwise
	_reporting = fmt::format("[ {} ]", turbo::str::join(_sink->get_progress(), ','));
#ifndef CIMBARD_NO_DEBUG
	std::cout << _reporting << std::endl;
#endif
	return res;
}

// mostly for internal use, but also helpful for debugging
unsigned cimbard_get_filesize(uint32_t id)
{
	FountainMetadata md(id);
	return md.file_size();
}

// do recover() if does not exist (fail with appropriate neg values), if it does use the bytes.
// stateful against a map (same as cimbard_decompress_read()
int cimbard_get_filename(uint32_t id, char* filename, unsigned fnsize)
{
	int	res = recover_contents(id);
	if (res < 0)
		return res;

	const uchar* finbuffer = _reassembled.data();
	unsigned size = _reassembled.size();

	std::string fn = cimbar::zstd_header_check::get_filename(finbuffer, size);
	if (!fn.empty())
		fn = File::basename(fn);
	if (fn.empty())
		return 0;

	if (fnsize < fn.size())
		fn.resize(fnsize);
	std::copy(fn.begin(), fn.end(), filename);
	return fn.size();
}

int cimbard_decompress_read(uint32_t id, unsigned char* buffer, unsigned size)
{
	int	res = recover_contents(id);
	if (res < 0)
		return res;

	if (!_dec)
		return -13;
	if (!_dec->good())
		return -14;

	_dec->str(std::string());
	bool wrote = _dec->write_once();
	std::string temp = _dec->str();
	// write_once() returns false both on clean EOF and on decompress error.
	// only an error populates last_error() -- use it to disambiguate, so a
	// corrupt stream isn't silently reported as a successful (truncated) read.
	if (!wrote && temp.empty() && !_dec->last_error().empty())
		return -15;
	if (size > temp.size())
		size = temp.size();
	std::copy(temp.data(), temp.data()+size, buffer);
	return size;
}

int cimbard_get_decompress_bufsize()
{
	return ZSTD_DStreamOutSize();
}

int cimbard_configure_decode(int mode_val)
{
	// defaults
	if (mode_val <= 0)
		mode_val = 68;

	bool refresh = (mode_val != _modeVal);
	_modeVal = mode_val;
	sync_thread_config();
	if (refresh)
		_sink.reset();

	return 0;
}

// Switch the per-frame decode mode but keep the fountain sink. Used by mode
// autodetect to probe other modes while a transfer is in progress: the sink is
// only valid for the mode it was created with, so a probe that finds data must
// be followed by cimbard_reset() + cimbard_configure_decode() before decoding it.
int cimbard_set_decode_mode_keep_sink(int mode_val)
{
	if (mode_val <= 0)
		mode_val = 68;
	_modeVal = mode_val;
	sync_thread_config();
	return 0;
}

int cimbard_reset()
{
	_sink.reset();
	_dec.reset();
	_decId = 0;
	_reassembled.clear();
	_reporting.clear();
	_debugFrame.release();
	return 0;
}

// testing
unsigned char* cimbard_get_reassembled_file_buff()
{
	if (_reassembled.empty())
		return nullptr;
	return _reassembled.data();
}

}
