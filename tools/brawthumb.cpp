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

int main(int argc, const char* argv[])
{
    if (argc < 3)
    {
        std::cerr << "Usage: " << argv[0] << " input.braw output.png [maxPixels=512]" << std::endl;
        return 1;
    }
    s_outputPath = argv[2];
    if (argc >= 4) s_maxPixels = (size_t)atoi(argv[3]);

    CFStringRef clipName = CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8);

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
