// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../config_specific/flutter/import_export/import_export.dart';
import '../../flutter/auto_dispose_mixin.dart';
import '../../flutter/common_widgets.dart';
import '../../flutter/controllers.dart';
import '../../flutter/notifications.dart';
import '../../flutter/octicons.dart';
import '../../flutter/screen.dart';
import '../../flutter/split.dart';
import '../../service_extensions.dart';
import '../../ui/flutter/label.dart';
import '../../ui/flutter/service_extension_widgets.dart';
import '../../ui/flutter/vm_flag_widgets.dart';
import '../timeline_controller.dart';
import '../timeline_model.dart';
import 'event_details.dart';
import 'flutter_frames_chart.dart';
import 'timeline_flame_chart.dart';

// TODO(kenz): handle small screen widths better by using Wrap instead of Row
// where applicable.

class TimelineScreen extends Screen {
  const TimelineScreen() : super();

  @visibleForTesting
  static const clearButtonKey = Key('Clear Button');
  @visibleForTesting
  static const flameChartSectionKey = Key('Flame Chart Section');
  @visibleForTesting
  static const pauseButtonKey = Key('Pause Button');
  @visibleForTesting
  static const resumeButtonKey = Key('Resume Button');
  @visibleForTesting
  static const emptyTimelineRecordingKey = Key('Empty Timeline Recording');
  @visibleForTesting
  static const recordButtonKey = Key('Record Button');
  @visibleForTesting
  static const recordingInstructionsKey = Key('Recording Instructions');
  @visibleForTesting
  static const recordingStatusKey = Key('Recording Status');
  @visibleForTesting
  static const stopRecordingButtonKey = Key('Stop Recording Button');

  @override
  Widget build(BuildContext context) => TimelineScreenBody();

  @override
  Widget buildTab(BuildContext context) {
    return const Tab(
      text: 'Timeline',
      icon: Icon(Octicons.pulse),
    );
  }
}

class TimelineScreenBody extends StatefulWidget {
  @override
  TimelineScreenBodyState createState() => TimelineScreenBodyState();
}

class TimelineScreenBodyState extends State<TimelineScreenBody>
    with AutoDisposeMixin {
  TimelineController controller;

  ExportController _exportController;

  TimelineMode get timelineMode => controller.timelineModeNotifier.value;

  bool recording = false;
  bool processing = false;
  double processingProgress = 0.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = Controllers.of(context).timeline;
    if (newController == controller) return;
    controller = newController;

    controller.timelineService.updateListeningState(true);

    cancel();
    addAutoDisposeListener(controller.timelineModeNotifier);
    addAutoDisposeListener(controller.fullTimeline.recordingNotifier, () {
      setState(() {
        recording = controller.fullTimeline.recordingNotifier.value;
      });
    });
    addAutoDisposeListener(controller.fullTimeline.processingNotifier, () {
      setState(() {
        processing = controller.fullTimeline.processingNotifier.value;
      });
    });
    addAutoDisposeListener(controller.fullTimeline.processor.progressNotifier,
        () {
      setState(() {
        processingProgress =
            controller.fullTimeline.processor.progressNotifier.value;
      });
    });
  }

  @override
  void dispose() {
    // TODO(kenz): make TimelineController disposable via
    // DisposableController and dispose here.
    controller.timelineService.updateListeningState(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildPrimaryStateControls(),
            _buildSecondaryControls(),
          ],
        ),
        if (timelineMode == TimelineMode.frameBased) const FlutterFramesChart(),
        ValueListenableBuilder<TimelineFrame>(
          valueListenable: controller.frameBasedTimeline.selectedFrameNotifier,
          builder: (context, selectedFrame, _) {
            return (timelineMode == TimelineMode.full || selectedFrame != null)
                ? Expanded(
                    child: Split(
                      axis: Axis.vertical,
                      firstChild: _buildFlameChartSection(),
                      secondChild: _buildEventDetailsSection(),
                      initialFirstFraction: 0.6,
                    ),
                  )
                : const SizedBox();
          },
        ),
      ],
    );
  }

  Widget _buildPrimaryStateControls() {
    const double minIncludeTextWidth = 950;
    final sharedWidgets = [
      const SizedBox(width: 8.0),
      clearButton(
        key: TimelineScreen.clearButtonKey,
        minIncludeTextWidth: minIncludeTextWidth,
        onPressed: () async {
          await _clearTimeline();
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0),
        child: Row(
          children: [
            Switch(
              value: timelineMode == TimelineMode.frameBased,
              onChanged: _onTimelineModeChanged,
            ),
            const Text('Show frames'),
          ],
        ),
      ),
    ];
    return timelineMode == TimelineMode.frameBased
        ? _buildFrameBasedTimelineButtons(sharedWidgets, minIncludeTextWidth)
        : _buildFullTimelineButtons(sharedWidgets, minIncludeTextWidth);
  }

  Widget _buildFrameBasedTimelineButtons(
    List<Widget> sharedWidgets,
    double minIncludeTextWidth,
  ) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.frameBasedTimeline.pausedNotifier,
      builder: (context, paused, _) {
        return Row(
          children: [
            OutlineButton(
              key: TimelineScreen.pauseButtonKey,
              onPressed: paused ? null : _pauseLiveTimeline,
              child: MaterialIconLabel(
                Icons.pause,
                'Pause',
                minIncludeTextWidth: minIncludeTextWidth,
              ),
            ),
            OutlineButton(
              key: TimelineScreen.resumeButtonKey,
              onPressed: !paused ? null : _resumeLiveTimeline,
              child: MaterialIconLabel(
                Icons.play_arrow,
                'Resume',
                minIncludeTextWidth: minIncludeTextWidth,
              ),
            ),
            ...sharedWidgets,
          ],
        );
      },
    );
  }

  Widget _buildFullTimelineButtons(
    List<Widget> sharedWidgets,
    double minIncludeTextWidth,
  ) {
    return Row(
      children: [
        recordButton(
          key: TimelineScreen.recordButtonKey,
          recording: recording,
          minIncludeTextWidth: minIncludeTextWidth,
          onPressed: _startRecording,
        ),
        stopRecordingButton(
          key: TimelineScreen.stopRecordingButtonKey,
          recording: recording,
          minIncludeTextWidth: minIncludeTextWidth,
          onPressed: _stopRecording,
        ),
        ...sharedWidgets,
      ],
    );
  }

  Widget _buildSecondaryControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ProfileGranularityDropdown(),
        ),
        ServiceExtensionButtonGroup(
          minIncludeTextWidth: 1300,
          extensions: [performanceOverlay, profileWidgetBuilds],
        ),
        const SizedBox(width: 8.0),
        OutlineButton(
          onPressed: _exportTimeline,
          child: MaterialIconLabel(
            Icons.file_download,
            'Export',
            minIncludeTextWidth: 1300,
          ),
        ),
      ],
    );
  }

  Widget _buildFlameChartSection() {
    Widget content;
    final fullTimelineEmpty = (controller.fullTimeline.data?.isEmpty ?? true) ||
        controller.fullTimeline.data.eventGroups.isEmpty;
    if (timelineMode == TimelineMode.full &&
        (recording || processing || fullTimelineEmpty)) {
      content = ValueListenableBuilder<bool>(
        valueListenable: controller.fullTimeline.emptyRecordingNotifier,
        builder: (context, emptyRecording, _) {
          return emptyRecording
              ? const Center(
                  key: TimelineScreen.emptyTimelineRecordingKey,
                  child: Text('No timeline events recorded'),
                )
              : _buildRecordingInfo();
        },
      );
    } else {
      content = TimelineFlameChart();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Container(
        key: TimelineScreen.flameChartSectionKey,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).focusColor),
        ),
        child: content,
      ),
    );
  }

  Widget _buildRecordingInfo() {
    return recordingInfo(
      instructionsKey: TimelineScreen.recordingInstructionsKey,
      recordingStatusKey: TimelineScreen.recordingStatusKey,
      recording: recording,
      processing: processing,
      progressValue: processingProgress,
      recordedObject: 'timeline trace',
    );
  }

  Widget _buildEventDetailsSection() {
    return ValueListenableBuilder<TimelineEvent>(
      valueListenable: controller.selectedTimelineEventNotifier,
      builder: (context, selectedEvent, _) {
        return EventDetails(selectedEvent);
      },
    );
  }

  void _pauseLiveTimeline() {
    setState(() {
      controller.frameBasedTimeline.pause(manual: true);
      controller.timelineService.updateListeningState(true);
    });
  }

  void _resumeLiveTimeline() {
    setState(() {
      controller.frameBasedTimeline.resume();
      controller.timelineService.updateListeningState(true);
    });
  }

  void _startRecording() async {
    await _clearTimeline();
    controller.fullTimeline.startRecording();
  }

  void _stopRecording() async {
    await controller.fullTimeline.stopRecording();
  }

  Future<void> _clearTimeline() async {
    await controller.clearData();
    setState(() {});
  }

  void _exportTimeline() {
    final exportedFile = _exportData();
    // TODO(kenz): investigate if we need to do any error handling here. Is the
    // download always successful?
    Notifications.of(context)
        .push('Successfully exported $exportedFile to ~/Downloads directory');
  }

  // TODO(kenz): move this to the controller once the dart:html app is deleted.
  // This code relies on `import_export.dart` which contains a flutter import.
  /// Exports the current timeline data to a .json file.
  ///
  /// This method returns the name of the file that was downloaded.
  String _exportData() {
    // TODO(kenz): add analytics for this. It would be helpful to know how
    // complex the problems are that users are trying to solve.
    final encodedTimelineData = jsonEncode(controller.timeline.data.json);
    final now = DateTime.now();
    final timestamp =
        '${now.year}_${now.month}_${now.day}-${now.microsecondsSinceEpoch}';
    final fileName = 'timeline_$timestamp.json';
    _exportController.downloadFile(fileName, encodedTimelineData);
    return fileName;
  }

  void _onTimelineModeChanged(bool frameBased) async {
    await _clearTimeline();
    controller.selectTimelineMode(
        frameBased ? TimelineMode.frameBased : TimelineMode.full);
  }
}
