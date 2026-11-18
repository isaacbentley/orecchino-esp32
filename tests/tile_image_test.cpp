// Host tests for map tiles as images: the format sniffer the fetch and the
// screens use (tile_path.h), the vendored JPEGDEC decoding a basemap JPEG to
// 8-bit grey (the T5) and RGB565 (the SenseCAP), and the T5's re-toning
// (map_tone.h). The fixture is a synthetic tile in Esri World Dark Gray's
// palette (tests/vectors/tiles/; no map imagery is redistributed). Set
// TILE_IMAGE_DIR to a folder of real tiles (*.jpg) to decode those too.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include "JPEGDEC.h"
#include "tile_path.h"
#include "map_tone.h"
#include <dirent.h>
#include <string>
#include <vector>

static int g_fails = 0;
#define CHECK(c, name) do { if (c) printf("ok   %s\n", name); else { printf("FAIL %s\n", name); g_fails++; } } while (0)

static std::vector<uint8_t> read_file(const char* path) {
  std::vector<uint8_t> v;
  FILE* f = fopen(path, "rb");
  if (!f) { printf("FAIL cannot open %s\n", path); g_fails++; return v; }
  uint8_t buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) v.insert(v.end(), buf, buf + n);
  fclose(f);
  return v;
}

// The decoded image, collected from JPEGDEC's blocks.
static uint8_t g_gray[256 * 256];
static uint16_t g_rgb[256 * 256];
static int g_px, g_bpp;
static int draw_cb(JPEGDRAW* d) {
  for (int r = 0; r < d->iHeight; r++)
    for (int c = 0; c < d->iWidth; c++) {
      int x = d->x + c, y = d->y + r;
      if (x < 0 || x >= 256 || y < 0 || y >= 256) continue;
      if (d->iBpp == 8) g_gray[y * 256 + x] = ((const uint8_t*)d->pPixels)[r * d->iWidth + c];
      else g_rgb[y * 256 + x] = d->pPixels[r * d->iWidth + c];
      g_px++;
    }
  g_bpp = d->iBpp;
  return 1;
}

static JPEGDEC g_jpeg;   // ~18 KB: not on the stack
static int g_err;        // JPEGDEC's last error (JPEG_SUCCESS...) after decode()
static bool g_opened;    // openRAM accepted the header

static bool decode(std::vector<uint8_t>& data, int type) {
  g_px = 0;
  g_opened = g_jpeg.openRAM(data.data(), (int)data.size(), draw_cb);
  g_err = g_jpeg.getLastError();
  if (!g_opened) return false;
  g_jpeg.setPixelType(type);   // after open, as the boards do
  bool ok = g_jpeg.getWidth() == 256 && g_jpeg.getHeight() == 256 && g_jpeg.decode(0, 0, 0) == 1;
  g_err = g_jpeg.getLastError();
  g_jpeg.close();
  return ok;
}

static void test_sniff() {
  const uint8_t jpg[] = { 0xFF, 0xD8, 0xFF, 0xE0 };
  const uint8_t png[] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0 };
  const char* html = "<html><body>API KEY REQUIRED</body></html>";
  CHECK(tile_sniff(jpg, sizeof(jpg)) == TILE_FMT_JPEG, "sniff: JPEG by its SOI marker");
  CHECK(tile_sniff(png, sizeof(png)) == TILE_FMT_PNG, "sniff: PNG by its signature (the fetch refuses it: CARTO's placeholder is a PNG)");
  CHECK(tile_sniff((const uint8_t*)html, strlen(html)) == TILE_FMT_NONE && tile_sniff(jpg, 2) == TILE_FMT_NONE,
        "sniff: an error page or two bytes are neither");
  CHECK(tile_path_ok("/tiles/15/5241/12665.jpg") && tile_path_ok("/tiles/15/5241/12665.png") &&
        !tile_path_ok("/tiles/15/5241/12665.jpeg") && !tile_path_ok("/tiles/15/5241/12665.l.png") &&
        !tile_path_ok(TILE_SOURCE_MARK), "paths: .jpg and .png tiles, nothing else (the source mark is not a tile)");
}

static void test_decode_gray() {
  auto data = read_file("tests/vectors/tiles/dark_gray_synthetic.jpg");
  CHECK(tile_sniff(data.data(), data.size()) == TILE_FMT_JPEG, "fixture: a JPEG");
  CHECK(decode(data, EIGHT_BIT_GRAYSCALE) && g_bpp == 8 && g_px >= 256 * 256, "T5: a colour JPEG decodes to 8-bit grey, every pixel");
  // Sample the known regions (away from JPEG ringing at edges).
  int water = g_gray[220 * 256 + 128], land = g_gray[4 * 256 + 30], block = g_gray[25 * 256 + 25],
      street = g_gray[80 * 256 + 50], road = g_gray[145 * 256 + 200];
  char name[160];
  snprintf(name, sizeof(name), "T5: grey levels water %d, land %d, block %d, street %d, major road %d", water, land, block, street, road);
  CHECK(abs(water - 34) <= 5 && abs(land - 77) <= 5 && abs(block - 70) <= 5 && abs(street - 100) <= 6 && abs(road - 125) <= 6, name);
  CHECK(map_tone_esri(water) == 9 && map_tone_esri(land) == 15 && map_tone_esri(block) == 15 &&
        map_tone_esri(street) == 6 && map_tone_esri(road) == 4, "T5: re-toned: water tint, land and blocks paper, streets dark, major road darker");
  int hist[16] = {0};
  for (int i = 0; i < 256 * 256; i++) hist[map_tone_esri(g_gray[i])]++;
  snprintf(name, sizeof(name), "T5: tones: paper %d%%, water %d%%, streets %d%%, labels %d px",
           hist[15] * 100 / 65536, hist[9] * 100 / 65536, (hist[6] + hist[4]) * 100 / 65536, hist[0]);
  CHECK(hist[15] > 65536 / 3 && hist[9] > 65536 / 5 && hist[6] + hist[4] > 65536 / 20 && hist[0] > 0, name);
  auto gray = read_file("tests/vectors/tiles/dark_gray_synthetic_gray.jpg");
  CHECK(decode(gray, EIGHT_BIT_GRAYSCALE) && abs(g_gray[4 * 256 + 30] - 77) <= 5, "T5: a greyscale JPEG decodes too");
}

static void test_decode_rgb565() {
  auto data = read_file("tests/vectors/tiles/dark_gray_synthetic.jpg");
  CHECK(decode(data, RGB565_LITTLE_ENDIAN) && g_bpp == 16 && g_px >= 256 * 256, "SenseCAP: decodes to RGB565");
  uint16_t c = g_rgb[4 * 256 + 30];
  int r = (c >> 11) << 3, g = ((c >> 5) & 0x3F) << 2, b = (c & 0x1F) << 3;
  CHECK(abs(r - 77) <= 10 && abs(g - 77) <= 10 && abs(b - 77) <= 10, "SenseCAP: land stays dark grey (the style is shown as it is)");
}

static void test_bad_data() {
  std::vector<uint8_t> junk(2000, 0x55);
  CHECK(!decode(junk, EIGHT_BIT_GRAYSCALE), "decode: junk is refused");
  auto data = read_file("tests/vectors/tiles/dark_gray_synthetic.jpg");
  CHECK(decode(data, EIGHT_BIT_GRAYSCALE) && g_err == JPEG_SUCCESS, "decode: (the whole tile decodes clean)");
  // Cut at a third (a download stopped short, before the fetch's rename
  // guard existed): the header opens, the rows it holds are drawn, then
  // decode() fails with JPEG_DECODE_ERROR instead of reading past the end
  // (ASan would say). The screens treat that as "no tile", not a crash.
  std::vector<uint8_t> cut(data.begin(), data.begin() + data.size() / 3);
  bool ok = decode(cut, EIGHT_BIT_GRAYSCALE);
  char name[120];
  snprintf(name, sizeof(name), "decode: a tile cut at a third opens, draws %d of 65536 px, then fails (error %d)", g_px, g_err);
  CHECK(!ok && g_opened && g_err == JPEG_DECODE_ERROR && g_px > 0 && g_px < 256 * 256, name);
  // Cut inside the header: it does not even open.
  std::vector<uint8_t> head(data.begin(), data.begin() + data.size() / 10);
  CHECK(!decode(head, EIGHT_BIT_GRAYSCALE) && !g_opened && g_px == 0, "decode: a tile cut inside its header does not open, draws nothing");
}

// Optional: real tiles (not in the repo).
static void test_real_tiles() {
  const char* dir = getenv("TILE_IMAGE_DIR");
  if (!dir) return;
  DIR* d = opendir(dir);
  if (!d) return;
  int n = 0, ok = 0;
  for (dirent* e; (e = readdir(d));) {
    std::string name = e->d_name;
    if (name.size() < 4 || name.substr(name.size() - 4) != ".jpg") continue;
    auto data = read_file((std::string(dir) + "/" + name).c_str());
    n++;
    if (!decode(data, EIGHT_BIT_GRAYSCALE)) continue;
    int hist[16] = {0};
    for (int i = 0; i < 256 * 256; i++) hist[map_tone_esri(g_gray[i])]++;
    printf("     %s: %zu bytes, paper %d%% water %d%% streets %d%% labels %d%%\n", name.c_str(), data.size(),
           hist[15] * 100 / 65536, hist[9] * 100 / 65536, (hist[6] + hist[4]) * 100 / 65536, hist[0] * 100 / 65536);
    ok++;
  }
  closedir(d);
  char msg[80];
  snprintf(msg, sizeof(msg), "real tiles: %d of %d decoded", ok, n);
  CHECK(ok == n, msg);
}

int main(void) {
  test_sniff();
  test_decode_gray();
  test_decode_rgb565();
  test_bad_data();
  test_real_tiles();
  if (g_fails) printf("%d FAILED\n", g_fails); else printf("all tile image checks passed\n");
  return g_fails ? 1 : 0;
}
