#version 440
// Shades one strand's ribbon (see waves.vert): smooth anti-aliased edge and the
// left-to-right theme gradient. Compile: ./build-shader.sh

layout(location = 0) in float vEdge;
layout(location = 1) in float vU;
layout(location = 2) in float vGap;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
  mat4 qt_Matrix;
  float qt_Opacity;
  vec2 size;
  vec4 amp;
  vec4 freq;
  vec4 phase;
  vec4 spread;
  vec4 fan;
  vec4 colorStart;
  vec4 colorEnd;
  float strands;
  float lineWidth;
  float centerY;
  float centerScale;
  float edgeScale;
  float pixel;
};

void main() {
  if (vGap > 0.5) discard;   // space between two strands
  float halfW = lineWidth * 0.5;
  float dist = abs(vEdge) * (halfW + pixel);   // distance from the centre line
  float cover = 1.0 - smoothstep(halfW - pixel * 0.5, halfW + pixel * 0.5, dist);
  vec3 col = mix(colorStart.rgb, colorEnd.rgb, vU);
  fragColor = vec4(col, 1.0) * cover * qt_Opacity;
}
