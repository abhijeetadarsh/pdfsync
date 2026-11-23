import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

/// Resize in the sizing delegate, before the legacy strategy can clamp zoom.
/// Using onViewSizeChanged instead reads an already-adjusted transform and
/// scales it a second time when a sidebar or a rotation changes the viewport.
class ResponsivePdfSizing extends PdfViewerSizeDelegateProviderLegacy {
  const ResponsivePdfSizing() : super(onePassRenderingScaleThreshold: 4);

  @override
  PdfViewerSizeDelegate create() => _ResponsivePdfSizeDelegate();

  @override
  bool operator ==(Object other) => other is ResponsivePdfSizing;

  @override
  int get hashCode => runtimeType.hashCode;
}

class _ResponsivePdfSizeDelegate extends PdfViewerSizeDelegateLegacy {
  _ResponsivePdfSizeDelegate()
      : super(
            maxScale: 8,
            minScale: .1,
            useAlternativeFitScaleAsMinScale: true,
            onePassRenderingScaleThreshold: 4,
            calculateInitialZoom: null);

  PdfViewerController? _viewer;

  @override
  void init(PdfViewerController controller) {
    super.init(controller);
    _viewer = controller;
  }

  @override
  void dispose() {
    _viewer = null;
    super.dispose();
  }

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) {
    final viewer = _viewer;
    if (viewer == null ||
        !isViewSizeChanged ||
        oldState.viewSize.width <= 0 ||
        newState.layout == null ||
        oldState.layout == null) {
      super.onLayoutUpdate(
          oldState: oldState,
          newState: newState,
          currentZoom: currentZoom,
          oldVisibleRect: oldVisibleRect,
          anchorPageNumber: anchorPageNumber,
          isLayoutChanged: isLayoutChanged,
          isViewSizeChanged: isViewSizeChanged);
      return;
    }
    // Both values belong to the same pre-resize snapshot. A fit-width page
    // stays fitted, while deliberate zoom retains its ratio to the pane width.
    final zoom =
        (currentZoom * newState.viewSize.width / oldState.viewSize.width)
            .clamp(newState.minScale, 8.0);
    final page = anchorPageNumber ?? 1;
    final hit =
        viewer.getClosestPageHit(page, oldState.layout!, oldVisibleRect);
    final number = (hit?.page.pageNumber ?? page)
        .clamp(1, newState.layout!.pageLayouts.length);
    final before = oldState.layout!.pageLayouts[number - 1];
    final after = newState.layout!.pageLayouts[number - 1];
    final relative = oldVisibleRect.topLeft - before.topLeft;
    final anchor = Offset(after.left + relative.dx / before.width * after.width,
        after.top + relative.dy / before.height * after.height);
    unawaited(viewer.goToPosition(
        documentOffset: anchor, zoom: zoom, duration: Duration.zero));
  }
}
