#version 440
// All strands of the wave ribbon as thin triangle strips in ONE GridMesh, so
// the GPU only shades the 2-3 pixels across each line. Mesh rows come in
// fours per strand: top edge, bottom edge, then two "gap" rows (a copy of this
// bottom edge and a copy of the next strand's top edge). Quads between equal
// rows have zero area; the real gap quad is pushed beyond the far plane, so it
// is clipped before rasterisation and never reaches the fragment shader.
// The curve is the sum of four sine lobes (bass = longest/largest .. treble =
// shortest/smallest); a strand's place t in the bundle shifts the phase and
// shrinks the amplitude, which fans the strands into a ribbon.
// Compile: ./build-shader.sh

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out float vEdge;   // -1..1 across the line
layout(location = 1) out float vU;      // 0..1 across the screen

layout(std140, binding = 0) uniform buf {
  mat4 qt_Matrix;
  float qt_Opacity;
  vec2 size;          // item size, logical px
  vec4 amp;           // amplitude per component, logical px
  vec4 freq;          // radians across the full width
  vec4 phase;         // current phase, radians
  vec4 spread;        // phase offset from first to last strand
  vec4 fan;           // amplitude drop from first to last strand (0..1)
  vec4 colorStart;
  vec4 colorEnd;
  float strands;      // number of strands
  float lineWidth;    // logical px
  float centerY;      // fraction of height
  float centerScale;  // amplitude multiplier at the middle of the screen
  float edgeScale;    // amplitude multiplier at the left/right edges
  float pixel;        // one device pixel, in logical px
};

const float PI = 3.14159265;

float curve(float u, float t, float halfExtent, float side) {
  vec4 theta = freq * u + phase + spread * t;
  vec4 a = amp * (1.0 - fan * t);
  float wave = dot(a, sin(theta));

  // Horizontal envelope: edgeScale at the sides, centerScale in the middle.
  float env = mix(edgeScale, centerScale, sin(PI * u));
  float dEnv = (centerScale - edgeScale) * PI * cos(PI * u) / size.x;
  float dy = env * dot(a * freq / size.x, cos(theta)) + dEnv * wave;   // slope

  // Extrude vertically by the half-thickness, stretched by the slope so the
  // line keeps the same perpendicular width on steep parts.
  return centerY * size.y + env * wave + side * halfExtent * sqrt(1.0 + dy * dy);
}

void main() {
  float u = qt_MultiTexCoord0.x;
  float rows = strands * 4.0;
  float r = floor(qt_MultiTexCoord0.y * (rows - 1.0) + 0.5);
  float strand = floor(r / 4.0);
  float k = r - strand * 4.0;          // 0 top, 1 bottom, 2 gap-bottom, 3 gap-top

  // The row after the last strand's bottom edge has no next strand: collapse
  // it onto that bottom edge.
  float next = min(strand + 1.0, strands - 1.0);
  float side = (k == 0.0 || k == 3.0) ? -1.0 : 1.0;
  float s = (k == 3.0) ? next : strand;
  if (k == 3.0 && next == strand) side = 1.0;
  float steps = max(strands - 1.0, 1.0);

  float halfExtent = lineWidth * 0.5 + pixel;
  float y = curve(u, s / steps, halfExtent, side);

  vEdge = side;
  vU = u;
  gl_Position = qt_Matrix * vec4(u * size.x, y, 0.0, 1.0);
  // Gap rows: z beyond w is outside clip space on every backend (GL -w..w,
  // Vulkan/Metal/D3D 0..w). Only the gap quad has all four corners there; its
  // neighbours keep zero area on screen, so nothing visible changes.
  if (k >= 2.0) gl_Position.z = 2.0 * gl_Position.w;
}
