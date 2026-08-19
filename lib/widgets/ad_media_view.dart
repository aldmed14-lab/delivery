import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_application_1/utils/ad_service.dart';

/// Renders an ad's media: a single video (autoplay, looped, muted by
/// default with a bottom-right toggle) when `filesType == "video"`, or an
/// image carousel that auto-advances every 3s and is swipeable when there
/// are multiple files, falling back to a plain image for a single file.
class AdMediaView extends StatefulWidget {
  final CachedAd ad;
  final double height;

  const AdMediaView({required this.ad, required this.height, super.key});

  @override
  State<AdMediaView> createState() => _AdMediaViewState();
}

class _AdMediaViewState extends State<AdMediaView> {
  // Image carousel state.
  final PageController _pageController = PageController();
  Timer? _autoSwitchTimer;
  int _page = 0;

  // Video state.
  VideoPlayerController? _videoController;
  bool _muted = true;
  bool _videoReady = false;

  @override
  void initState() {
    super.initState();
    if (widget.ad.filesType == 'video') {
      _initVideo();
    } else if (widget.ad.files.length > 1) {
      _autoSwitchTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!mounted || !_pageController.hasClients) return;
        final next = (_page + 1) % widget.ad.files.length;
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  void _initVideo() {
    final url = widget.ad.files.isNotEmpty ? widget.ad.files.first : null;
    if (url == null) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoController = controller;
    controller.setVolume(0);
    controller.setLooping(true);
    controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _videoReady = true);
      controller.play();
    });
  }

  void _toggleMute() {
    final controller = _videoController;
    if (controller == null) return;
    setState(() {
      _muted = !_muted;
      controller.setVolume(_muted ? 0 : 1);
    });
  }

  @override
  void dispose() {
    _autoSwitchTimer?.cancel();
    _pageController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ad.filesType == 'video') {
      final controller = _videoController;
      return SizedBox(
        height: widget.height,
        width: double.infinity,
        child: !_videoReady || controller == null
            ? Container(color: Colors.grey[200])
            : Stack(
                fit: StackFit.expand,
                children: [
                  FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: controller.value.size.width,
                      height: controller.value.size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: GestureDetector(
                      onTap: _toggleMute,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _muted ? Icons.volume_off : Icons.volume_up,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      );
    }

    final files = widget.ad.files;
    if (files.length <= 1) {
      final url = files.isNotEmpty ? files.first : null;
      return SizedBox(
        height: widget.height,
        width: double.infinity,
        child: url != null
            ? CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(color: Colors.grey[200]),
                errorWidget: (c, u, e) => Container(color: Colors.grey[200]),
              )
            : Container(color: Colors.grey[200]),
      );
    }

    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: files.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => CachedNetworkImage(
              imageUrl: files[i],
              fit: BoxFit.cover,
              placeholder: (c, u) => Container(color: Colors.grey[200]),
              errorWidget: (c, u, e) => Container(color: Colors.grey[200]),
            ),
          ),
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(files.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: active ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
