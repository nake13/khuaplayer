#pragma once

extern "C" {
#include <libavformat/avformat.h>
#include <libavutil/display.h>
}

#include <cmath>

namespace sp {

// Clockwise quarter turn (0, 90, 180 or 270) that shows a stream upright.
// Phones record portrait video as landscape samples plus a display matrix;
// players must apply it, as FFmpeg's autorotate does. Off-axis angles snap to
// the nearest quarter turn. A mirroring matrix only reports its rotation part.
inline int spClockwiseRotationForDisplayMatrix(const int32_t* matrix) {
    if (!matrix) return 0;
    const double ccw = av_display_rotation_get(matrix);
    if (std::isnan(ccw)) return 0;
    const int quarter = (int)std::lround(-ccw / 90.0);
    return ((quarter % 4) + 4) % 4 * 90;
}

inline int spStreamClockwiseRotation(const AVStream* st) {
    if (!st || !st->codecpar) return 0;
    const AVPacketSideData* sd = av_packet_side_data_get(
        st->codecpar->coded_side_data, st->codecpar->nb_coded_side_data,
        AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * sizeof(int32_t)) return 0;
    return spClockwiseRotationForDisplayMatrix(reinterpret_cast<const int32_t*>(sd->data));
}

inline bool spRotationSwapsAxes(int clockwiseDegrees) {
    return clockwiseDegrees == 90 || clockwiseDegrees == 270;
}

}  // namespace sp
