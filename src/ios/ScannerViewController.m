//
//  DriverLicense.m
//  CodeLib
//
//  Created by Александр Ушаков on 15/05/14.
//  Copyright (c) 2014 Александр Ушаков. All rights reserved.
//

#include <mach/mach_host.h>
#import "ScannerViewController.h"
#import <BarcodeScanner/Barcode2DScanner.h>
#include <mach/mach_host.h>

#define MAX_THREADS 2

@implementation ScannerViewController {
    AVCaptureSession *_captureSession;
    AVCaptureDevice *_device;
    AVCaptureVideoPreviewLayer *_prevLayer;
    bool running;
    int activeThreads;
    int availableThreads;
    NSString * lastFormat;
    Barcode2DScanner* scanner;
    
    MainScreenState state;
    
    CGImageRef    decodeImage;
    NSString *    decodeResult;
    size_t width;
    size_t height;
    size_t bytesPerRow;
    unsigned char *baseAddress;
    NSTimer *focusTimer;
    
    int param_ZoomLevel1;
    int param_ZoomLevel2;
    int zoomLevel;
    bool videoZoomSupported;
    float firstZoom;
    float secondZoom;
}

@synthesize captureSession = _captureSession;
@synthesize prevLayer = _prevLayer;
@synthesize device = _device;
@synthesize state;
@synthesize focusTimer;

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
#if TARGET_IPHONE_SIMULATOR
    NSLog(@"On iOS simulator camera is not Supported");
#else
    [self initCapture];
#endif
    [self startScanning];
}

- (void)viewWillDisappear:(BOOL) animated {
    [super viewWillDisappear:animated];
    [self stopScanning];
    [self deinitCapture];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.prevLayer = nil;
    
    param_ZoomLevel1 = 0; //set automatic
    param_ZoomLevel2 = 0; //set automatic
    zoomLevel = 0;
    [[NSNotificationCenter defaultCenter] addObserver: self selector:@selector(decodeResultNotification:) name: DecoderResultNotification object: nil];
}

// IOS 7 statusbar hide
- (BOOL)prefersStatusBarHidden
{
    return YES;
}

-(void) reFocus {
    //NSLog(@"refocus");
    
    NSError *error;
    if ([self.device lockForConfiguration:&error]) {
        
        if ([self.device isFocusPointOfInterestSupported]){
            [self.device setFocusPointOfInterest:CGPointMake(0.49,0.49)];
            [self.device setFocusMode:AVCaptureFocusModeAutoFocus];
        }
        [self.device unlockForConfiguration];
        
    }
}

- (void)toggleTorch
{
    if ([self.device isTorchModeSupported:AVCaptureTorchModeOn]) {
        NSError *error;
        
        if ([self.device lockForConfiguration:&error]) {
            if ([self.device torchMode] == AVCaptureTorchModeOn)
                [self.device setTorchMode:AVCaptureTorchModeOff];
            else
                [self.device setTorchMode:AVCaptureTorchModeOn];
            
            if([self.device isFocusModeSupported: AVCaptureFocusModeContinuousAutoFocus])
                self.device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            
            [self.device unlockForConfiguration];
        } else {
            
        }
    }
}

- (void)initCapture
{
    scanner = [[Barcode2DScanner alloc] init];
    [scanner registerCode:[[NSUserDefaults standardUserDefaults] objectForKey:@"cameraKey"]];
    /*We setup the input*/
    self.device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    AVCaptureDeviceInput *captureInput = [AVCaptureDeviceInput deviceInputWithDevice:self.device error:nil];
    /*We setupt the output*/
    
    if (captureInput == nil){
        NSString *appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString*)kCFBundleNameKey];
        [[[UIAlertView alloc] initWithTitle:@"Camera Unavailable" message:[NSString stringWithFormat:@"The %@ has not been given a permission to your camera. Please check the Privacy Settings: Settings -> %@ -> Privacy -> Camera", appName, appName] delegate:nil cancelButtonTitle:@"OK" otherButtonTitles: nil] show];
        
        return;
    }
    
    AVCaptureVideoDataOutput *captureOutput = [[AVCaptureVideoDataOutput alloc] init];
    captureOutput.alwaysDiscardsLateVideoFrames = YES;
    //captureOutput.minFrameDuration = CMTimeMake(1, 10); Uncomment it to specify a minimum duration for each video frame
    [captureOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    // Set the video output to store frame in BGRA (It is supposed to be faster)
    
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    // Set the video output to store frame in 422YpCbCr8(It is supposed to be faster)
    
    //************************Note this line
    NSNumber* value = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange];
    
    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:value forKey:key];
    [captureOutput setVideoSettings:videoSettings];
    
    //And we create a capture session
    self.captureSession = [[AVCaptureSession alloc] init];
    //We add input and output
    [self.captureSession addInput:captureInput];
    [self.captureSession addOutput:captureOutput];
    
    
    // Limit camera FPS to 15 for single core devices (iPhone 4 and older) so more CPU power is available for decoder
    host_basic_info_data_t hostInfo;
    mach_msg_type_number_t infoCount;
    infoCount = HOST_BASIC_INFO_COUNT;
    host_info( mach_host_self(), HOST_BASIC_INFO, (host_info_t)&hostInfo, &infoCount ) ;
    
    if ([self.captureSession canSetSessionPreset:AVCaptureSessionPresetHigh])
    {
        NSLog(@"Set preview port to 1920x1080");
        self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;
    } else
        //set to 640x480 if 1280x720 not supported on device
        if ([self.captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720])
        {
            NSLog(@"Set preview port to 1280x720");
            self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
        }
    
    host_info( mach_host_self(), HOST_BASIC_INFO, (host_info_t)&hostInfo, &infoCount ) ;
    
    if (hostInfo.max_cpus < 2){
        if ([self.device respondsToSelector:@selector(setActiveVideoMinFrameDuration:)]){
            [self.device lockForConfiguration:nil];
            [self.device setActiveVideoMinFrameDuration:CMTimeMake(1, 15)];
            [self.device unlockForConfiguration];
        } else {
            AVCaptureConnection *conn = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
            [conn setVideoMinFrameDuration:CMTimeMake(1, 15)];
        }
    }
    
    NSLog(@"hostInfo.max_cpus %d",hostInfo.max_cpus);
    availableThreads = MIN(MAX_THREADS, hostInfo.max_cpus);
    activeThreads = 0;
    
    
    /*We add the preview layer*/
    
    self.prevLayer = [AVCaptureVideoPreviewLayer layerWithSession: self.captureSession];
    
    if (self.interfaceOrientation == UIInterfaceOrientationLandscapeLeft){
        self.prevLayer.connection.videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
        self.prevLayer.frame = CGRectMake(0, 0, MAX(self.view.frame.size.width,self.view.frame.size.height), MIN(self.view.frame.size.width,self.view.frame.size.height));
    }
    if (self.interfaceOrientation == UIInterfaceOrientationLandscapeRight){
        self.prevLayer.connection.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
        self.prevLayer.frame = CGRectMake(0, 0, MAX(self.view.frame.size.width,self.view.frame.size.height), MIN(self.view.frame.size.width,self.view.frame.size.height));
    }
    
    
    if (self.interfaceOrientation == UIInterfaceOrientationPortrait) {
        self.prevLayer.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
        self.prevLayer.frame = CGRectMake(0, 0, MIN(self.view.frame.size.width,self.view.frame.size.height), MAX(self.view.frame.size.width,self.view.frame.size.height));
    }
    if (self.interfaceOrientation == UIInterfaceOrientationPortraitUpsideDown) {
        self.prevLayer.connection.videoOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
        self.prevLayer.frame = CGRectMake(0, 0, MIN(self.view.frame.size.width,self.view.frame.size.height), MAX(self.view.frame.size.width,self.view.frame.size.height));
        
    }
    
    
    self.prevLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer: self.prevLayer];
#if USE_MWOVERLAY
    [MWOverlay addToPreviewLayer:self.prevLayer];
#endif
    
    videoZoomSupported = false;
    
    if ([self.device respondsToSelector:@selector(setActiveFormat:)] &&
        [self.device.activeFormat respondsToSelector:@selector(videoMaxZoomFactor)] &&
        [self.device respondsToSelector:@selector(setVideoZoomFactor:)]){
        
        float maxZoom = 0;
        if ([self.device.activeFormat respondsToSelector:@selector(videoZoomFactorUpscaleThreshold)]){
            maxZoom = self.device.activeFormat.videoZoomFactorUpscaleThreshold;
        } else {
            maxZoom = self.device.activeFormat.videoMaxZoomFactor;
        }
        
        float maxZoomTotal = self.device.activeFormat.videoMaxZoomFactor;
        
        if ([self.device respondsToSelector:@selector(setVideoZoomFactor:)] && maxZoomTotal > 1.1){
            videoZoomSupported = true;
            
            
            
            if (param_ZoomLevel1 != 0 && param_ZoomLevel2 != 0){
                
                if (param_ZoomLevel1 > maxZoomTotal * 100){
                    param_ZoomLevel1 = (int)(maxZoomTotal * 100);
                }
                if (param_ZoomLevel2 > maxZoomTotal * 100){
                    param_ZoomLevel2 = (int)(maxZoomTotal * 100);
                }
                
                firstZoom = 0.01 * param_ZoomLevel1;
                secondZoom = 0.01 * param_ZoomLevel2;
                
                
            } else {
                
                if (maxZoomTotal > 2){
                    
                    if (maxZoom > 1.0 && maxZoom <= 2.0){
                        firstZoom = maxZoom;
                        secondZoom = maxZoom * 2;
                    } else
                        if (maxZoom > 2.0){
                            firstZoom = 2.0;
                            secondZoom = 4.0;
                        }
                    
                }
            }
            
            
        } else {
            
        }
        
        
        
        
    }
    
    self.focusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(reFocus) userInfo:nil repeats:YES];
    
    [self CustomeOverlay];
}

- (void) CustomeOverlay
{
    [self.view bringSubviewToFront:self.btn];
    [self.view bringSubviewToFront:self.demoLbl];
}

- (void) onVideoStart: (NSNotification*) note
{
    if(running)
        return;
    running = YES;
    
    // lock device and set focus mode
    NSError *error = nil;
    if([self.device lockForConfiguration: &error])
    {
        if([self.device isFocusModeSupported: AVCaptureFocusModeContinuousAutoFocus])
            self.device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
    }
}

- (void) onVideoStop: (NSNotification*) note
{
    if(!running)
        return;
    [self.device unlockForConfiguration];
    running = NO;
}

#pragma mark -
#pragma mark AVCaptureSession delegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (state != CAMERA) {
        return;
    }
    
    if (self.state != CAMERA_DECODING)
    {
        self.state = CAMERA_DECODING;
    }
    
    activeThreads++;
    
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    //Lock the image buffer
    CVPixelBufferLockBaseAddress(imageBuffer,0);
    //Get information about the image
    baseAddress = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer,0);
    int pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            //NSLog(@"Capture pixel format=NV12");
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,0);
            width = bytesPerRow;//CVPixelBufferGetWidthOfPlane(imageBuffer,0);
            height = CVPixelBufferGetHeightOfPlane(imageBuffer,0);
            break;
        case kCVPixelFormatType_422YpCbCr8:
            //NSLog(@"Capture pixel format=UYUY422");
            bytesPerRow = (int) CVPixelBufferGetBytesPerRowOfPlane(imageBuffer,0);
            width = CVPixelBufferGetWidth(imageBuffer);
            height = CVPixelBufferGetHeight(imageBuffer);
            int len = width*height;
            int dstpos=1;
            for (int i=0;i<len;i++){
                baseAddress[i]=baseAddress[dstpos];
                dstpos+=2;
            }
            
            break;
        default:
            //    NSLog(@"Capture pixel format=RGB32");
            break;
    }
    
    unsigned char *frameBuffer = malloc(width * height);
    memcpy(frameBuffer, baseAddress, width * height);
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        NSString* result = [scanner scanGrayscaleImage: frameBuffer Width: width Height: height];
        
        free(frameBuffer);
        
        //CVPixelBufferUnlockBaseAddress(imageBuffer,0);
        
        //ignore results less than 4 characters - probably false detection
        if ( [result length] > 4 )
        {
            NSLog(@"Detected PDF417: %@", result);
            self.state = CAMERA;
            
            if (decodeImage != nil)
            {
                CGImageRelease(decodeImage);
                decodeImage = nil;
            }
            
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                [self.captureSession stopRunning];
                NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
                DecoderResult *notificationResult = [DecoderResult createSuccess:result];
                [center postNotificationName:DecoderResultNotification object: notificationResult];
            });
        }
        else
        {
            self.state = CAMERA;
        }
        activeThreads --;
    });
    
}



#pragma mark -
#pragma mark Memory management

- (void)viewDidUnload
{
    [self stopScanning];
    
    self.prevLayer = nil;
    [super viewDidUnload];
}

- (void)dealloc {
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) startScanning {
    self.state = LAUNCHING_CAMERA;
    [self.captureSession startRunning];
    self.prevLayer.hidden = NO;
    self.state = CAMERA;
}

- (void)stopScanning {
    [self.captureSession stopRunning];
    self.state = NORMAL;
    self.prevLayer.hidden = YES;
    
    
}

- (void) deinitCapture {
    if (self.focusTimer){
        [self.focusTimer invalidate];
        self.focusTimer = nil;
    }
    
    if (self.captureSession != nil){
#if USE_MWOVERLAY
        [MWOverlay removeFromPreviewLayer];
#endif
        
#if !__has_feature(objc_arc)
        [self.captureSession release];
#endif
        self.captureSession=nil;
        
        [self.prevLayer removeFromSuperlayer];
        self.prevLayer = nil;
    }
}


- (void)decodeResultNotification: (NSNotification *)notification {
    
    if ([notification.object isKindOfClass:[DecoderResult class]])
    {
        DecoderResult *obj = (DecoderResult*)notification.object;
        if (obj.succeeded)
        {
            decodeResult = [[NSString alloc] initWithString:obj.result];
            UIAlertView * messageDlg = [[UIAlertView alloc] initWithTitle:[NSString stringWithFormat:@"Format: %@",lastFormat] message:decodeResult
                                                                 delegate:self cancelButtonTitle:nil otherButtonTitles:@"Close", nil];
            [messageDlg show];
        }
    }
}

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 0) {
        //To continue scanning
        [self startScanning];
    }
}

- (NSUInteger)supportedInterfaceOrientations {
    
    
    UIInterfaceOrientation interfaceOrientation =[[UIApplication sharedApplication] statusBarOrientation];
    
    switch (interfaceOrientation) {
        case UIInterfaceOrientationPortrait:
            return UIInterfaceOrientationMaskPortrait;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIInterfaceOrientationMaskPortraitUpsideDown;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            return UIInterfaceOrientationMaskLandscapeLeft;
            break;
        case UIInterfaceOrientationLandscapeRight:
            return UIInterfaceOrientationMaskLandscapeRight;
            break;
            
        default:
            break;
    }
    
    return UIInterfaceOrientationMaskAll;
    
}

- (BOOL) shouldAutorotate {
    
    return YES;
    
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [self toggleTorch];
    
}

- (void)doZoomToggle:(id)sender {
    
    zoomLevel++;
    if (zoomLevel > 2){
        zoomLevel = 0;
    }
    
    [self updateDigitalZoom];
    
}

- (void) updateDigitalZoom {
    
    if (videoZoomSupported){
        
        [self.device lockForConfiguration:nil];
        
        switch (zoomLevel) {
            case 0:
                [self.device setVideoZoomFactor:1 /*rampToVideoZoomFactor:1 withRate:4*/];
                break;
            case 1:
                [self.device setVideoZoomFactor:firstZoom /*rampToVideoZoomFactor:firstZooom withRate:4*/];
                break;
            case 2:
                [self.device setVideoZoomFactor:secondZoom /*rampToVideoZoomFactor:secondZoom withRate:4*/];
                break;
                
            default:
                break;
        }
        [self.device unlockForConfiguration];
        
    }
}

- (IBAction)closeBtn:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

/*
 *  Implementation of the object that returns decoder results (via the notification
 *    process)
 */

@implementation DecoderResult

@synthesize succeeded;
@synthesize result;

+(DecoderResult *)createSuccess:(NSString *)result {
    DecoderResult *obj = [[DecoderResult alloc] init];
    if (obj != nil) {
        obj.succeeded = YES;
        obj.result = result;
    }
    return obj;
}

+(DecoderResult *)createFailure {
    DecoderResult *obj = [[DecoderResult alloc] init];
    if (obj != nil) {
        obj.succeeded = NO;
        obj.result = nil;
    }
    return obj;
}

- (void)dealloc {
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
    self.result = nil;
}

@end


