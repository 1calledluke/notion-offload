// brawthumb — extract a downscaled first-frame PNG from a .braw clip.
// Usage: brawthumb input.braw output.png [maxPixels=512]
// Built on the Blackmagic RAW SDK's ExtractFrame sample (BSD-style license).

#include "BlackmagicRawAPI.h"

#include <iostream>
#include <string>

#include <CoreServices/CoreServices.h>
#include <ImageIO/ImageIO.h>

static const BlackmagicRawResourceFormat s_resourceFormat = blackmagicRawResourceFormatRGBAU8;

static std::string s_outputPath;
static size_t s_maxPixels = 512;
static bool s_wroteImage = false;

static void OutputImage(uint32_t width, uint32_t height, uint32_t sizeBytes, void* imageData)
{
    CFStringRef pathStr = CFStringCreateWithCString(kCFAllocatorDefault, s_outputPath.c_str(), kCFStringEncodingUTF8);
    CFURLRef file = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, pathStr, kCFURLPOSIXPathStyle, false);
    if (file == nullptr) { CFRelease(pathStr); return; }

    const uint32_t bitsPerComponent = 8;
    const uint32_t bitsPerPixel     = 32;
    const uint32_t bytesPerRow      = (bitsPerPixel * width) / 8U;

    CGColorSpaceRef space      = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bitmapInfo    = kCGImageAlphaNoneSkipLast | kCGImageByteOrderDefault;
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, imageData, sizeBytes, nullptr);

    CGImageRef fullImage = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow,
                                         space, bitmapInfo, provider, nullptr, false,
                                         kCGRenderingIntentDefault);
    if (fullImage != nullptr)
    {
        // Downscale so icons stay small (fit within s_maxPixels).
        double scale = (double)s_maxPixels / (double)(width > height ? width : height);
        if (scale > 1.0) scale = 1.0;
        size_t outW = (size_t)(width * scale);
        size_t outH = (size_t)(height * scale);

        CGContextRef ctx = CGBitmapContextCreate(nullptr, outW, outH, 8, 0, space,
                                                 kCGImageAlphaNoneSkipLast | kCGImageByteOrderDefault);
        CGImageRef outImage = nullptr;
        if (ctx != nullptr)
        {
            CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
            CGContextDrawImage(ctx, CGRectMake(0, 0, outW, outH), fullImage);
            outImage = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
        }

        CGImageRef toWrite = outImage != nullptr ? outImage : fullImage;
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL(file, CFSTR("public.png"), 1, nullptr);
        if (destination)
        {
            CGImageDestinationAddImage(destination, toWrite, nil);
            if (CGImageDestinationFinalize(destination)) s_wroteImage = true;
            CFRelease(destination);
        }
        if (outImage != nullptr) CGImageRelease(outImage);
        CGImageRelease(fullImage);
    }

    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    CFRelease(file);
    CFRelease(pathStr);
}

class ThumbCallback : public IBlackmagicRawCallback
{
public:
    explicit ThumbCallback() = default;
    virtual ~ThumbCallback() = default;

    virtual void ReadComplete(IBlackmagicRawJob* readJob, HRESULT result, IBlackmagicRawFrame* frame)
    {
        IBlackmagicRawJob* decodeAndProcessJob = nullptr;
        if (result == S_OK) result = frame->SetResourceFormat(s_resourceFormat);
        if (result == S_OK) result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeAndProcessJob);
        if (result == S_OK) result = decodeAndProcessJob->Submit();
        if (result != S_OK && decodeAndProcessJob) decodeAndProcessJob->Release();
        readJob->Release();
    }

    virtual void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* processedImage)
    {
        unsigned int width = 0, height = 0, sizeBytes = 0;
        void* imageData = nullptr;
        if (result == S_OK) result = processedImage->GetWidth(&width);
        if (result == S_OK) result = processedImage->GetHeight(&height);
        if (result == S_OK) result = processedImage->GetResourceSizeBytes(&sizeBytes);
        if (result == S_OK) result = processedImage->GetResource(&imageData);
        if (result == S_OK) OutputImage(width, height, sizeBytes, imageData);
        job->Release();
    }

    virtual void DecodeComplete(IBlackmagicRawJob*, HRESULT) {}
    virtual void TrimProgress(IBlackmagicRawJob*, float) {}
    virtual void TrimComplete(IBlackmagicRawJob*, HRESULT) {}
    virtual void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) {}
    virtual void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) {}
    virtual void PreparePipelineComplete(void*, HRESULT) {}
    virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) { return E_NOTIMPL; }
    virtual ULONG STDMETHODCALLTYPE AddRef(void) { return 0; }
    virtual ULONG STDMETHODCALLTYPE Release(void) { return 0; }
};

// --audio mode: extract the clip's audio track to a PCM WAV (SDK reads it
// directly from the braw container — no proxy needed for transcription).
static int ExtractAudioToWav(IBlackmagicRawClip* clip, const char* outPath)
{
    IBlackmagicRawClipAudio* audio = nullptr;
    if (clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio) != S_OK || !audio)
    {
        std::cerr << "no audio track" << std::endl;
        return 4;
    }

    uint64_t audioSamples = 0; uint32_t bitDepth = 0, channelCount = 0, sampleRate = 0;
    if (audio->GetAudioSampleCount(&audioSamples) != S_OK ||
        audio->GetAudioBitDepth(&bitDepth) != S_OK ||
        audio->GetAudioChannelCount(&channelCount) != S_OK ||
        audio->GetAudioSampleRate(&sampleRate) != S_OK ||
        audioSamples == 0 || channelCount == 0)
    {
        audio->Release();
        std::cerr << "no audio samples" << std::endl;
        return 4;
    }

    struct __attribute__((packed)) WavHeader {
        char riff[4] = {'R','I','F','F'}; uint32_t contentSize = 0;
        char wave[4] = {'W','A','V','E'}; char fmt[4] = {'f','m','t',' '};
        uint32_t fmtSize = 16; uint16_t format = 1;
        uint16_t channels = 0; uint32_t rate = 0; uint32_t byteRate = 0;
        uint16_t align = 0; uint16_t bits = 0;
        char data[4] = {'d','a','t','a'}; uint32_t dataBytes = 0;
    } hdr;
    hdr.channels = (uint16_t)channelCount;
    hdr.rate = sampleRate;
    hdr.bits = (uint16_t)bitDepth;
    hdr.byteRate = sampleRate * bitDepth * channelCount / 8;
    hdr.align = (uint16_t)((bitDepth * channelCount) / 8);
    uint64_t dataBytes = (audioSamples * channelCount * bitDepth) / 8;
    hdr.dataBytes = (uint32_t)dataBytes;
    hdr.contentSize = 36 + (uint32_t)dataBytes;

    FILE* out = fopen(outPath, "wb");
    if (!out) { audio->Release(); return 4; }
    fwrite(&hdr, sizeof(hdr), 1, out);

    constexpr uint32_t maxSamples = 48000;
    uint32_t bufSize = (maxSamples * channelCount * bitDepth) / 8;
    int8_t* buf = new int8_t[bufSize];
    uint64_t index = 0;
    HRESULT r = S_OK;
    while (r == S_OK && index < audioSamples)
    {
        uint32_t samplesRead = 0, bytesRead = 0;
        r = audio->GetAudioSamples(index, buf, bufSize, maxSamples, &samplesRead, &bytesRead);
        if (r == S_OK && bytesRead > 0) fwrite(buf, bytesRead, 1, out);
        if (samplesRead == 0) break;
        index += samplesRead;
    }
    delete[] buf;
    fclose(out);
    audio->Release();
    std::cout << outPath << std::endl;
    return 0;
}

// --camera mode: print the clip's camera_type metadata (header read, instant —
// exiftool needs -ee which scans the whole multi-GB stream).
static int PrintCameraType(IBlackmagicRawClip* clip)
{
    IBlackmagicRawMetadataIterator* it = nullptr;
    if (clip->GetMetadataIterator(&it) != S_OK || it == nullptr)
        return 3;

    int found = 3;
    CFStringRef key = nullptr;
    while (it->GetKey(&key) == S_OK && key != nullptr)
    {
        char keyBuf[256] = {0};
        CFStringGetCString(key, keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8);
        if (strcmp(keyBuf, "camera_type") == 0)
        {
            Variant v;
            VariantInit(&v);
            if (it->GetData(&v) == S_OK && v.vt == blackmagicRawVariantTypeString && v.bstrVal)
            {
                char valBuf[512] = {0};
                CFStringGetCString(v.bstrVal, valBuf, sizeof(valBuf), kCFStringEncodingUTF8);
                std::cout << valBuf << std::endl;
                found = 0;
            }
            VariantClear(&v);
            break;
        }
        if (it->Next() != S_OK) break;
    }
    it->Release();
    return found;
}

int main(int argc, const char* argv[])
{
    bool cameraMode = argc >= 3 && strcmp(argv[1], "--camera") == 0;
    bool audioMode  = argc >= 4 && strcmp(argv[1], "--audio") == 0;
    if (argc < 3)
    {
        std::cerr << "Usage: " << argv[0] << " input.braw output.png [maxPixels=512]\n"
                  << "       " << argv[0] << " --camera input.braw\n"
                  << "       " << argv[0] << " --audio input.braw output.wav" << std::endl;
        return 1;
    }
    const char* inputPath = (cameraMode || audioMode) ? argv[2] : argv[1];
    const char* audioOut = audioMode ? argv[3] : nullptr;
    if (!cameraMode && !audioMode)
    {
        s_outputPath = argv[2];
        if (argc >= 4) s_maxPixels = (size_t)atoi(argv[3]);
    }

    CFStringRef clipName = CFStringCreateWithCString(NULL, inputPath, kCFStringEncodingUTF8);

    // The decoder framework ships with several Blackmagic installs — try each.
    const char* libraryPaths[] = {
        "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries",
        "/Applications/Blackmagic RAW/Blackmagic RAW Player.app/Contents/Frameworks",
    };

    IBlackmagicRawFactory* factory = nullptr;
    for (const char* p : libraryPaths)
    {
        CFStringRef libPath = CFStringCreateWithCString(NULL, p, kCFStringEncodingUTF8);
        factory = CreateBlackmagicRawFactoryInstanceFromPath(libPath);
        CFRelease(libPath);
        if (factory != nullptr) break;
    }
    if (factory == nullptr)
    {
        std::cerr << "Failed to load Blackmagic RAW library (is Blackmagic RAW installed?)" << std::endl;
        CFRelease(clipName);
        return 2;
    }

    HRESULT result = S_OK;
    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    IBlackmagicRawJob* readJob = nullptr;
    ThumbCallback callback;

    do
    {
        if (factory->CreateCodec(&codec) != S_OK) { std::cerr << "CreateCodec failed" << std::endl; result = E_FAIL; break; }
        if (codec->OpenClip(clipName, &clip) != S_OK) { std::cerr << "OpenClip failed" << std::endl; result = E_FAIL; break; }
        if (cameraMode)
        {
            int rc = PrintCameraType(clip);
            clip->Release(); codec->Release(); factory->Release(); CFRelease(clipName);
            return rc;
        }
        if (audioMode)
        {
            int rc = ExtractAudioToWav(clip, audioOut);
            clip->Release(); codec->Release(); factory->Release(); CFRelease(clipName);
            return rc;
        }
        if (codec->SetCallback(&callback) != S_OK) { std::cerr << "SetCallback failed" << std::endl; result = E_FAIL; break; }
        if (clip->CreateJobReadFrame(0, &readJob) != S_OK) { std::cerr << "CreateJobReadFrame failed" << std::endl; result = E_FAIL; break; }
        if (readJob->Submit() != S_OK) { readJob->Release(); std::cerr << "Submit failed" << std::endl; result = E_FAIL; break; }
        codec->FlushJobs();
    } while (0);

    if (clip) clip->Release();
    if (codec) codec->Release();
    if (factory) factory->Release();
    CFRelease(clipName);

    if (!s_wroteImage) { std::cerr << "No image written" << std::endl; return 3; }
    std::cout << s_outputPath << std::endl;
    return 0;
}
