/*
 * ofGstVideoUtils.cpp
 *
 *  Created on: 16/01/2011
 *      Author: arturo
 */

#include "ofGstVideoPlayer.h"
#include <gst/gst.h>
#include <gst/video/video.h>
#include <gst/audio/multichannel.h>
#include <gst/app/gstappsink.h>
#include <gst/net/gstnet.h>
#include <gst/gstiterator.h>

static gboolean
g_object_property_exists(GObject* object, const gchar* property_name)
{
    if (!object || !property_name)
        return FALSE;
    {
        GParamSpec* spec;
        spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), property_name);
        return ((spec) ? TRUE : FALSE);
    }
}

static gboolean
g_object_property_exists_of_type(GObject* object, const gchar* property_name, GType g_type)
{
    if (!object || !property_name)
        return FALSE;
    {
        GParamSpec* spec;
        spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), property_name);
        if (!spec)
            return FALSE;
        if (g_type == G_TYPE_INVALID || g_type == spec->value_type || g_type_is_a(spec->value_type, g_type))
            return TRUE;
        return FALSE;
    }
}


ofGstVideoPlayer::ofGstVideoPlayer(){
	nFrames						= 0;
	internalPixelFormat			= OF_PIXELS_RGB;
	bIsStream					= false;
	bIsAllocated				= false;
    bIsSynced                   = false;
	threadAppSink				= false;
	videoUtils.setSinkListener(this);
}

ofGstVideoPlayer::~ofGstVideoPlayer(){
	close();
}

bool ofGstVideoPlayer::setPixelFormat(ofPixelFormat pixelFormat){
	internalPixelFormat = pixelFormat;
	return true;
}

ofPixelFormat ofGstVideoPlayer::getPixelFormat(){
	return internalPixelFormat;
}

void ofGstVideoPlayer::setSync(SYNC_TYPE sType, GstClockTime bTime){
    bIsSynced = true;
    syncType  = sType;
    baseTime  = bTime;
}

void ofGstVideoPlayer::playbin_element_added (GstElement *playbin, GstElement *element, ofGstVideoPlayer *app)
{
    gchar* factory_name;
    GstElementFactory* factory;
    if (!element)
        return;
    
    factory = gst_element_get_factory(element);
    if (!factory)
        return;
    
    factory_name = GST_PLUGIN_FEATURE_NAME(factory);
    if (!g_str_has_prefix(factory_name, "uridecodebin"))
        return;
    
    examine_element(factory_name, element, app);

    //g_object_set(element, "download", (app->download_disabled ? FALSE : TRUE), NULL);
    //g_object_set(element, "use-buffering", (app->buffering_disabled ? FALSE : TRUE), NULL);
    
    //g_signal_connect(element, "pad-added", G_CALLBACK(uridecodebin_pad_added), app);
    g_signal_connect(element, "element-added", G_CALLBACK(uridecodebin_element_added), app);
}

void ofGstVideoPlayer::uridecodebin_element_added(GstBin* uridecodebin, GstElement* element, ofGstVideoPlayer *app)
{
    gchar* factory_name;
    GstElementFactory* factory;
    if (!element)
        return;
    
    factory = gst_element_get_factory(element);
    if (!factory)
        return;
    
    factory_name = GST_PLUGIN_FEATURE_NAME(factory);
    
    cout << "URIDECODEBIN: " << factory_name << endl;

    
    if (g_str_has_prefix(factory_name, "decodebin")) {
        g_signal_connect(element, "element-added", G_CALLBACK(decodebin_element_added), app);
    }
    if (g_str_has_prefix(factory_name, "rtspsrc")) {
        g_signal_connect(element, "element-added", G_CALLBACK(rtspsrc_element_added), app);
    }
    
    examine_element(factory_name, element, app);
}

void ofGstVideoPlayer::rtspsrc_element_added(GstBin* decodebin, GstElement* element, ofGstVideoPlayer *app)
{
    gchar* factory_name;
    GstElementFactory* factory;
    
    if (!element)
        return;
    
    factory = gst_element_get_factory(element);
    if (!factory)
        return;
    
    factory_name = GST_PLUGIN_FEATURE_NAME(factory);
    {
        cout << "RTSPSRC: " << factory_name << endl;
        examine_element(factory_name, element, app);
        
        if (g_str_has_prefix(factory_name, "gstrtpbin")) {
            g_signal_connect(element, "element-added", G_CALLBACK(rtpbin_element_added), app);
        }

    }
}

void ofGstVideoPlayer::decodebin_element_added(GstBin* decodebin, GstElement* element, ofGstVideoPlayer *app)
{
    gchar* factory_name;
    GstElementFactory* factory;
    
    if (!element)
        return;
    
    factory = gst_element_get_factory(element);
    if (!factory)
        return;
    
    factory_name = GST_PLUGIN_FEATURE_NAME(factory);
    
    {
        /*
        gboolean is_now_live = FALSE;
        gboolean was_live = app->is_live;
        
        if (g_str_has_prefix(factory_name, "multipartdemux")) {
            app->has_multipartdemux = TRUE;
        } else if (g_str_has_prefix(factory_name, "jpegdec")) {
            app->has_jpegdec = TRUE;
        }
        */
        cout << "DECODEBIN: " << factory_name << endl;
        examine_element(factory_name, element, app);
        
        /* We reevaluate if this is a live pipeline by determining if the user explicitly set it or if they have all the trappings of one. */
        //app->is_live = is_now_live = was_live || (app->has_multipartdemux && app->has_jpegdec && !app->has_fps);
        
        /* If we've determined that this is a live pipeline, then reexamine the elements and apply properties that may fit now. */
        //examine_elements(GST_BIN(app->gstPipeline), app);
        
        /* If we previously thought that the pipeline wasn't live, then we may be buffering. Instruct the pipeline to continue. */
        //if (!was_live && is_now_live)
        //    gst_element_set_state(app->getGstVideoUtils()->getPipeline(), GST_STATE_PLAYING);
    }
}

void ofGstVideoPlayer::rtpbin_element_added(GstBin* rtpbin, GstElement* element, ofGstVideoPlayer *app)
{
    gchar* factory_name;
    GstElementFactory* factory;
    
    if (!element)
        return;
    
    factory = gst_element_get_factory(element);
    if (!factory)
        return;
    
    factory_name = GST_PLUGIN_FEATURE_NAME(factory);
    
    {
        cout << "RTPBIN: " << factory_name << endl;
        examine_element(factory_name, element, app);
    }
}


void ofGstVideoPlayer::examine_elements(GstBin* bin, ofGstVideoPlayer *app)
{
    gboolean done;
    GstIterator* iter;
    GstElementFactory* factory;
    gpointer p;
    
    done = FALSE;
    iter = gst_bin_iterate_recurse(bin);
    
    if (!iter)
        return;
    
    while (!done) {
        switch(gst_iterator_next(iter, &p)) {
            case GST_ITERATOR_OK:
                GstElement* element;
                element = GST_ELEMENT(p);
                factory = gst_element_get_factory(element);
                if (factory)
                    examine_element(GST_PLUGIN_FEATURE_NAME(factory), element, app);
                gst_object_unref(element);
                break;
            case GST_ITERATOR_RESYNC:
                gst_iterator_resync(iter);
                break;
            case GST_ITERATOR_ERROR:
            case GST_ITERATOR_DONE:
                done = TRUE;
                break;
        }
    }
    
    gst_iterator_free(iter);
}

void ofGstVideoPlayer::examine_element(gchar* factory_name, GstElement* element, ofGstVideoPlayer *app)
{
    if (!element)
        return;
    
    if (g_str_has_prefix(factory_name, "multipartdemux")) {
        
        if (g_object_property_exists(G_OBJECT(element), "single-stream"))
            g_object_set(element, "single-stream", TRUE, NULL);
        
    } else if (g_str_has_prefix(factory_name, "jpegdec")) {
        
        if (g_object_property_exists(G_OBJECT(element), "max-errors"))
            g_object_set(element, "max-errors", 10, NULL);
        
        /* Change IDCT method to float. On x86 processors, the output is noticeably better. */
        g_object_set(element, "idct-method", 2, NULL);
        
    } else if (g_str_has_prefix(factory_name, "souphttpsrc")) {
        
        //if (app->is_live) {
            g_object_set(element, "do-timestamp", TRUE, NULL);
            g_object_set(element, "is-live", TRUE, NULL);
        //}
        g_object_set(element, "timeout", 3, NULL);
        g_object_set(element, "automatic-redirect", TRUE, NULL);
        
    } else if (g_str_has_prefix(factory_name, "neonhttpsrc")) {
        
        //if (app->is_live) {
            g_object_set(element, "do-timestamp", TRUE, NULL);
        //}
        g_object_set(element, "accept-self-signed", TRUE, NULL);
        g_object_set(element, "connect-timeout", 3, NULL);
        g_object_set(element, "read-timeout", 3, NULL);
        g_object_set(element, "automatic-redirect", TRUE, NULL);
        
    } else if (g_str_has_prefix(factory_name, "udpsrc")) {
        //g_object_set(element, "buffer-size", 1000, NULL);
        //g_object_set(element, " do-timestamp", TRUE, NULL);
        
    } else if (g_str_has_prefix(factory_name, "rtspsrc")) {
        g_object_set(element, "latency", 0, NULL);
        g_object_set(element, "buffer-mode", 0, NULL);
        //g_object_set(element, "drop-on-latency", TRUE, NULL);
        g_object_set(element, "udp-buffer-size", 150000, NULL);
        //g_object_set(element, "debug", TRUE, NULL);

    } else if (g_str_has_prefix(factory_name, "uridecodebin")) {
        g_object_set(element, "buffer-duration", 0, NULL);
        
    } else if (g_str_has_prefix(factory_name, "gstrtpbin")) {
        g_object_set(element, "buffer-mode", 0, NULL);
        g_object_set(element, "latency", 0, NULL);
        //g_object_set(element, "use-pipeline-clock", TRUE, NULL);

    } else if (g_str_has_prefix(factory_name, "ffdec_h264")) {
        g_object_set(element, "max-threads", 0, NULL);
        
    } else if (g_str_has_prefix(factory_name, "gstrtpjitterbuffer")) {
        //g_object_set(element, "drop-on-latency", TRUE, NULL);
        //g_object_set(element, "latency", 0, NULL);
        //g_object_set(element, "mode", 0, NULL);
        //g_object_set(element, "do-lost", TRUE, NULL);
    }
}


void ofGstVideoPlayer::configure_source (GstElement *src, GstPad *new_pad, ofGstVideoPlayer *app)
{
    cout << "Configured Source!!!!! $$$$$!%@%&@%@&@%&@&@&%@$@&%$@&@@&@&@" << endl;
}


bool ofGstVideoPlayer::loadMovie(string name){
	close();
	if( name.find( "file://",0 ) != string::npos){
		bIsStream		= false;
	}else if( name.find( "://",0 ) == string::npos){
		name 			= "file://"+ofToDataPath(name,true);
		bIsStream		= false;
	}else{
		bIsStream		= true;
	}
	ofLog(OF_LOG_VERBOSE,"loading "+name);

	ofGstUtils::startGstMainLoop();

	gstPipeline = gst_element_factory_make("playbin2","player");
	g_object_set(G_OBJECT(gstPipeline), "uri", name.c_str(), (void*)NULL);
        
    g_signal_connect(gstPipeline, "element-added", G_CALLBACK(playbin_element_added), this);

    g_signal_connect (gstPipeline, "notify::source", G_CALLBACK (configure_source), NULL);
    
    if (bIsSynced) {
        
        gint port = 1234;
        const gchar *ip_address = "127.0.0.1";
        GstClock *clock;

        switch (syncType) {
                
            case SYNC_MASTER:
            {
                // disable the pipeline's management of base_time -- we're going to set it ourselves.
                clock = gst_pipeline_get_clock(GST_PIPELINE(gstPipeline));
                
                GstClockTime base_time = gst_clock_get_time(clock);
                cout << "Using clock: " << base_time << endl;
                gst_pipeline_use_clock(GST_PIPELINE(gstPipeline), clock);
                
                // this will start a server listening on a UDP port                
                gst_net_time_provider_new(clock, ip_address, port);
                
                gst_element_set_start_time(gstPipeline, GST_CLOCK_TIME_NONE);
                gst_element_set_base_time(gstPipeline, baseTime);
                printf("Start Master as: [IP] %s [PORT] %d [BASE TIME] %lld\n", ip_address, port, baseTime);
                break;
            }
                
            case SYNC_SLAVE:
            {
                // disable the pipeline's management of base_time -- we're going to set it ourselves.
                gst_element_set_start_time(gstPipeline, GST_CLOCK_TIME_NONE);
                gst_element_set_base_time(gstPipeline, baseTime);

                // make a clock slaving to the network
                clock = gst_net_client_clock_new(NULL, ip_address, port, baseTime);
                // use it in the pipeline
                gst_pipeline_use_clock(GST_PIPELINE(gstPipeline), clock);
                
                printf("Start Slave as: [IP] %s [PORT] %d [BASE TIME] %lld\n", ip_address, port, baseTime);
                break;
            }
                
            default:
                break;
        }
    }
    
    
    
    
	// create the oF appsink for video rgb without sync to clock
	GstElement * gstSink = gst_element_factory_make("appsink", "app_sink");

	gst_base_sink_set_sync(GST_BASE_SINK(gstSink), true);
    //gst_base_sink_set_async_enabled(GST_BASE_SINK(gstSink), true);
	gst_app_sink_set_max_buffers(GST_APP_SINK(gstSink), 0);
	//gst_app_sink_set_drop (GST_APP_SINK(gstSink),true);
    //gst_app_sink_set_emit_signals (GST_APP_SINK(gstSink), true);
        
	gst_base_sink_set_max_lateness  (GST_BASE_SINK(gstSink), -1);

    /*
    Try setting the "do-timestamp" property on appsrc to TRUE, maybe also
    set "format" to GST_FORMAT_TIME, "is-live" to TRUE and "max-latency" to
    something suitable.
    
    You can set "sync" to FALSE on the sink to test if that's likely to be
        the problem (that's not an actual solution though, just for
                     diagnostics).
     */
    
    
	int bpp;
	string mime;
	switch(internalPixelFormat){
	case OF_PIXELS_MONO:
		mime = "video/x-raw-gray";
		bpp = 8;
		break;
	case OF_PIXELS_RGB:
		mime = "video/x-raw-rgb";
		bpp = 24;
		break;
	case OF_PIXELS_RGBA:
	case OF_PIXELS_BGRA:
		mime = "video/x-raw-rgb";
		bpp = 32;
		break;
	default:
		mime = "video/x-raw-rgb";
		bpp=24;
		break;
	}

	GstCaps *caps = gst_caps_new_simple(mime.c_str(),
										"bpp", G_TYPE_INT, bpp,
										"depth", G_TYPE_INT, 24,
										"endianness",G_TYPE_INT,4321,
										"red_mask",G_TYPE_INT,0xff0000,
										"green_mask",G_TYPE_INT,0x00ff00,
										"blue_mask",G_TYPE_INT,0x0000ff,
										"alpha_mask",G_TYPE_INT,0x000000ff,


										NULL);
	gst_app_sink_set_caps(GST_APP_SINK(gstSink), caps);
	gst_caps_unref(caps);

	if(threadAppSink){
		GstElement * appQueue = gst_element_factory_make("queue","appsink_queue");
		g_object_set(G_OBJECT(appQueue), "leaky", 0, "silent", 1, (void*)NULL);
		GstElement* appBin = gst_bin_new("app_bin");
		gst_bin_add(GST_BIN(appBin), appQueue);
		GstPad* appQueuePad = gst_element_get_static_pad(appQueue, "sink");
		GstPad* ghostPad = gst_ghost_pad_new("app_bin_sink", appQueuePad);
		gst_object_unref(appQueuePad);
		gst_element_add_pad(appBin, ghostPad);

		gst_bin_add_many(GST_BIN(appBin), gstSink, NULL);
		gst_element_link_many(appQueue, gstSink, NULL);

		g_object_set (G_OBJECT(gstPipeline),"video-sink",appBin,(void*)NULL);
	}else{
		g_object_set (G_OBJECT(gstPipeline),"video-sink",gstSink,(void*)NULL);
	}

#ifdef TARGET_WIN32
	GstElement *audioSink = gst_element_factory_make("directsoundsink", NULL);
	g_object_set (G_OBJECT(gstPipeline),"audio-sink",audioSink,(void*)NULL);

#endif



    //rtsp://10.0.1.100/axis-media/media.amp?videocodec=h264&camera=0
    
	//if(!videoUtils.setPipelineWithSink(gstPipeline,gstSink,bIsStream))
    //{
    //    return false;
    //}
    videoUtils.setPipelineWithSink(gstPipeline,gstSink,bIsStream);
    
    /*
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::source::rtpbin0::latency", 500, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::source::rtpbin1::latency", 500, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::source::rtpbin2::latency", 500, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::source::rtpbin3::latency", 500, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::source::rtpbin0::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::source::rtpbin1::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::source::rtpbin2::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::source::rtpbin3::buffer-mode", 0, NULL);

    
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::source::rtpbin0::latency", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::source::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::buffer-size", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin0::source::udpsrc0::buffer-size", 0, NULL);
    
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::source::rtpbin1::latency", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::source::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::buffer-size", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin1::source::udpsrc1::buffer-size", 0, NULL);

    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::source::rtpbin2::latency", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::source::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::buffer-size", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin2::source::udpsrc2::buffer-size", 0, NULL);

    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::source::rtpbin3::latency", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::source::buffer-mode", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::buffer-size", 0, NULL);
    gst_child_proxy_set(GST_OBJECT(gstPipeline), "uridecodebin3::source::udpsrc3::buffer-size", 0, NULL);
    
     */
    
	if(!bIsStream){
        return allocate(bpp);
    } else { 
        return true;
    }
}


void ofGstVideoPlayer::setThreadAppSink(bool threaded){
	threadAppSink = threaded;
}


bool ofGstVideoPlayer::allocate(int bpp){
	if(bIsAllocated) return true;

	guint64 durationNanos = videoUtils.getDurationNanos();

	nFrames		  = 0;
	if(GstPad* pad = gst_element_get_static_pad(videoUtils.getSink(), "sink")){
		int width,height;
		if(gst_video_get_size(GST_PAD(pad), &width, &height)){
			if(!videoUtils.allocate(width,height,bpp)) return false;
		}else{
			ofLog(OF_LOG_ERROR,"GStreamer: cannot query width and height");
			return false;
		}

		const GValue *framerate;
		framerate = gst_video_frame_rate(pad);
		fps_n=0;
		fps_d=0;
		if(framerate && GST_VALUE_HOLDS_FRACTION (framerate)){
			fps_n = gst_value_get_fraction_numerator (framerate);
			fps_d = gst_value_get_fraction_denominator (framerate);
			nFrames = (float)(durationNanos / GST_SECOND) * (float)fps_n/(float)fps_d;
			ofLog(OF_LOG_VERBOSE,"ofGstUtils: framerate: %i/%i",fps_n,fps_d);
		}else{
			ofLog(OF_LOG_WARNING,"Gstreamer: cannot get framerate, frame seek won't work");
		}
		gst_object_unref(GST_OBJECT(pad));
		bIsAllocated = true;
	}else{
		ofLog(OF_LOG_ERROR,"GStreamer: cannot get sink pad");
		bIsAllocated = false;
	}

	return bIsAllocated;
}

void ofGstVideoPlayer::on_stream_prepared(){
	if(!bIsAllocated) allocate(24);
}

int	ofGstVideoPlayer::getCurrentFrame(){
	int frame = 0;

	// zach I think this may fail on variable length frames...
	float pos = getPosition();
	if(pos == -1) return -1;


	float  framePosInFloat = ((float)getTotalNumFrames() * pos);
	int    framePosInInt = (int)framePosInFloat;
	float  floatRemainder = (framePosInFloat - framePosInInt);
	if (floatRemainder > 0.5f) framePosInInt = framePosInInt + 1;
	//frame = (int)ceil((getTotalNumFrames() * getPosition()));
	frame = framePosInInt;

	return frame;
}

int	ofGstVideoPlayer::getTotalNumFrames(){
	return nFrames;
}

void ofGstVideoPlayer::firstFrame(){
	setFrame(0);
}

void ofGstVideoPlayer::nextFrame(){
	gint64 currentFrame = getCurrentFrame();
	if(currentFrame!=-1) setFrame(currentFrame + 1);
}

void ofGstVideoPlayer::previousFrame(){
	gint64 currentFrame = getCurrentFrame();
	if(currentFrame!=-1) setFrame(currentFrame - 1);
}

void ofGstVideoPlayer::setFrame(int frame){ // frame 0 = first frame...
	float pct = (float)frame / (float)nFrames;
	setPosition(pct);
}

bool ofGstVideoPlayer::isStream(){
	return bIsStream;
}

void ofGstVideoPlayer::update(){
	videoUtils.update();
}

void ofGstVideoPlayer::play(){
	videoUtils.play();
}

void ofGstVideoPlayer::stop(){
	videoUtils.stop();
}

void ofGstVideoPlayer::setPaused(bool bPause){
	videoUtils.setPaused(bPause);
}

bool ofGstVideoPlayer::isPaused(){
	return videoUtils.isPaused();
}

bool ofGstVideoPlayer::isLoaded(){
	return videoUtils.isLoaded();
}

bool ofGstVideoPlayer::isPlaying(){
	return videoUtils.isPlaying();
}

float ofGstVideoPlayer::getPosition(){
	return videoUtils.getPosition();
}

float ofGstVideoPlayer::getSpeed(){
	return videoUtils.getSpeed();
}

float ofGstVideoPlayer::getDuration(){
	return videoUtils.getDuration();
}

bool ofGstVideoPlayer::getIsMovieDone(){
	return videoUtils.getIsMovieDone();
}

void ofGstVideoPlayer::setPosition(float pct){
	videoUtils.setPosition(pct);
}

void ofGstVideoPlayer::setVolume(float volume){
	videoUtils.setVolume(volume);
}

void ofGstVideoPlayer::setLoopState(ofLoopType state){
	videoUtils.setLoopState(state);
}

ofLoopType ofGstVideoPlayer::getLoopState(){
	return videoUtils.getLoopState();
}

void ofGstVideoPlayer::setSpeed(float speed){
	videoUtils.setSpeed(speed);
}

void ofGstVideoPlayer::close(){
	bIsAllocated = false;
	videoUtils.close();
}

bool ofGstVideoPlayer::isFrameNew(){
	return videoUtils.isFrameNew();
}

unsigned char * ofGstVideoPlayer::getPixels(){
	return videoUtils.getPixels();
}

ofPixelsRef ofGstVideoPlayer::getPixelsRef(){
	return videoUtils.getPixelsRef();
}

float ofGstVideoPlayer::getHeight(){
	return videoUtils.getHeight();
}

float ofGstVideoPlayer::getWidth(){
	return videoUtils.getWidth();
}

ofGstVideoUtils * ofGstVideoPlayer::getGstVideoUtils(){
	return &videoUtils;
}

void ofGstVideoPlayer::setFrameByFrame(bool frameByFrame){
	videoUtils.setFrameByFrame(frameByFrame);
}
