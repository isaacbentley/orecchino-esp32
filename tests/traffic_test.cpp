// Host test for firmware/common/traffic.h against every shared vector in
// tests/vectors/traffic/*.json (the same files TrafficRulesTests.swift and
// mobile/test/traffic_rules_test.dart load), plus C-only edge cases.
// Aircraft in the vectors are in the wire format of the `traffic` host line
// and go through the firmware's own parser (traffic_parse_aircraft).
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <algorithm>
#include <string>
#include <vector>
#include "traffic.h"

static int g_fails = 0, g_checks = 0;
static std::string g_ctx;
#define CHECK(c, ...) do { g_checks++; if (!(c)) { g_fails++; printf("FAIL [%s] ", g_ctx.c_str()); \
  printf(__VA_ARGS__); printf("\n"); } } while (0)

// ------------------------------------------------------------ tiny JSON reader
struct J {
  enum T { NUL, BOOL, NUM, STR, ARR, OBJ } t = NUL;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<J> a;
  std::vector<std::pair<std::string, J>> o;
  std::string raw;                                  // source text of this value
  const J* get(const char* k) const {
    for (auto& kv : o) if (kv.first == k) return &kv.second;
    return nullptr;
  }
  bool has(const char* k) const { return get(k) != nullptr; }
  double num(const char* k) const { const J* v = get(k); return v && v->t == NUM ? v->n : NAN; }
  std::string str(const char* k) const { const J* v = get(k); return v && v->t == STR ? v->s : ""; }
  bool boolean(const char* k) const { const J* v = get(k); return v && v->t == BOOL && v->b; }
};

static const char* jws(const char* p) { while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') p++; return p; }

static const char* jparse(const char* p, J& out) {
  p = jws(p);
  const char* start = p;
  if (*p == '{') {
    out.t = J::OBJ; p = jws(p + 1);
    if (*p == '}') p++;
    else for (;;) {
      J key; p = jparse(p, key); p = jws(p); if (*p != ':') return nullptr;
      J val; p = jparse(p + 1, val); if (!p) return nullptr;
      out.o.emplace_back(key.s, val);
      p = jws(p);
      if (*p == ',') { p++; continue; }
      if (*p == '}') { p++; break; }
      return nullptr;
    }
  } else if (*p == '[') {
    out.t = J::ARR; p = jws(p + 1);
    if (*p == ']') p++;
    else for (;;) {
      J val; p = jparse(p, val); if (!p) return nullptr;
      out.a.push_back(val);
      p = jws(p);
      if (*p == ',') { p++; continue; }
      if (*p == ']') { p++; break; }
      return nullptr;
    }
  } else if (*p == '"') {
    out.t = J::STR; p++;
    while (*p && *p != '"') {
      if (*p == '\\') { p++; char c = *p++; out.s += (c == 'n' ? '\n' : c); continue; }
      out.s += *p++;
    }
    if (*p != '"') return nullptr;
    p++;
  } else if (!strncmp(p, "true", 4)) { out.t = J::BOOL; out.b = true; p += 4; }
  else if (!strncmp(p, "false", 5)) { out.t = J::BOOL; p += 5; }
  else if (!strncmp(p, "null", 4)) { out.t = J::NUL; p += 4; }
  else { char* e; out.t = J::NUM; out.n = strtod(p, &e); if (e == p) return nullptr; p = e; }
  out.raw.assign(start, p);
  return p;
}

static double jnull(const J* v) { return v && v->t == J::NUM ? v->n : NAN; }

static bool near_eq(double got, const J* want, double tol) {
  if (!want || want->t == J::NUL) return isnan(got);
  if (isnan(got)) return false;
  return fabs(got - want->n) <= tol;
}

// Banned words: "clear" only as the instruction "KEEP CLEAR OF"; "conflict"
// only in "conflict watch" / "ADS-B conflict(s)", never "conflict resolved".
static bool forbidden(const std::string& s) {
  std::string l = s;
  for (auto& c : l) c = (char)tolower((unsigned char)c);
  for (size_t p; (p = l.find("keep clear of")) != std::string::npos;) l.erase(p, 13);
  for (const char* w : {"collision", "safe", "clear", "tcas", "conflict resolved", "no traffic"})
    if (l.find(w) != std::string::npos) return true;
  return false;
}

// ------------------------------------------------------------ rule vectors
static const uint32_t T0 = 1000000;

static TrafficObserver observer_of(const J* o) {   // LOW's observer; host_lines: the ingest filter
  TrafficObserver ob = {NAN, NAN, NAN};
  if (!o) return ob;
  ob.lat = jnull(o->get("lat")); ob.lon = jnull(o->get("lon")); ob.elev_m = jnull(o->get("elev_m"));
  return ob;
}

static int g_steps = 0, g_alerts = 0, g_hand = 0;

// The vector's "hand_checks": numbers derived by hand from the scenario
// (right triangles, the CPA formula), never from an implementation, so a
// geometry slip shared by all three ports still fails. horiz_m / vert_m
// within tol_m (0.5 m unless given), bearing within 0.05 deg, cpa_s within
// 0.05 s; a null field must be unknown; an absent one is not checked.
static void run_hand_checks(const J& v, const J& step, const TrafficResult& r) {
  const J* hc = v.get("hand_checks");
  if (!hc) return;
  for (const J& c : hc->a) {
    if (c.num("t_s") != step.num("t_s")) continue;
    const TrafficAlert* m = nullptr;
    int found = 0;
    for (int i = 0; i < r.n; i++) {
      const TrafficAlert& a = r.alerts[i];
      if (c.str("hex") != a.hex) continue;
      if (c.has("drone") && c.str("drone") != a.drone_id) continue;
      if (c.has("kind") && c.str("kind") != traffic_kind_name(a.kind)) continue;
      m = &a;
      found++;
    }
    CHECK(found == 1, "hand check %s finds one alert (%d)", c.str("hex").c_str(), found);
    if (found != 1) continue;
    double tol = c.has("tol_m") ? c.num("tol_m") : 0.5;
    if (c.has("horiz_m")) CHECK(near_eq(m->horiz_m, c.get("horiz_m"), tol), "hand %s horiz %.3f want %g", m->hex, m->horiz_m, c.num("horiz_m"));
    if (c.has("vert_m")) CHECK(near_eq(m->vert_m, c.get("vert_m"), tol), "hand %s vert %.3f want %g", m->hex, m->vert_m, c.num("vert_m"));
    if (c.has("bearing_deg")) CHECK(near_eq(m->bearing_deg, c.get("bearing_deg"), 0.05), "hand %s bearing %.3f want %g", m->hex, m->bearing_deg, c.num("bearing_deg"));
    if (c.has("cpa_s")) CHECK(near_eq(m->cpa_s, c.get("cpa_s"), 0.05), "hand %s cpa %.3f want %g", m->hex, m->cpa_s, c.num("cpa_s"));
    g_hand++;
  }
}

static void run_rule_vector(const J& v) {
  TrafficState st;
  traffic_state_reset(&st);
  for (const J& step : v.get("steps")->a) {
    char ctx[96];
    snprintf(ctx, sizeof(ctx), "%s t=%g", v.str("name").c_str(), step.num("t_s"));
    g_ctx = ctx;
    uint32_t now = T0 + (uint32_t)llround(step.num("t_s") * 1000.0);
    const J* dj = step.has("drones") ? step.get("drones") : v.get("drones");
    std::vector<TrafficDrone> drones;
    if (dj) for (const J& d : dj->a) {
      TrafficDrone x;
      memset(&x, 0, sizeof(x));
      snprintf(x.id, sizeof(x.id), "%s", d.str("id").c_str());
      x.lat = jnull(d.get("lat")); x.lon = jnull(d.get("lon"));
      x.alt_geo_m = jnull(d.get("alt_geo_m")); x.speed_mps = jnull(d.get("speed_mps"));
      x.heading_deg = jnull(d.get("heading_deg")); x.live = d.boolean("live");
      x.height_m = jnull(d.get("height_m"));
      drones.push_back(x);
    }
    TrafficObserver ob = observer_of(step.has("observer") ? step.get("observer") : v.get("observer"));
    std::vector<TrafficAircraft> ac;
    for (const J& w : step.get("aircraft")->a) {
      TrafficAircraft a;
      bool ok = traffic_parse_aircraft(w.raw.c_str(), now, &a, nullptr);
      CHECK(ok, "aircraft %s parses", w.str("hex").c_str());
      if (ok) ac.push_back(a);
    }
    const J* da = step.get("data_age_s");
    bool have = da && da->t == J::NUM;
    uint32_t data_ms = have ? now - (uint32_t)llround(da->n * 1000.0) : 0;
    TrafficResult r;
    traffic_evaluate(drones.data(), (int)drones.size(), ac.data(), (int)ac.size(), &ob,
                     have, data_ms, now, &st, &r);
    const J& e = *step.get("expect");
    char sum[96];
    traffic_summary(&r, sum, sizeof(sum));
    CHECK(r.have_data == e.boolean("have_data"), "have_data");
    CHECK(r.stale == e.boolean("stale"), "stale %d", r.stale);
    CHECK(e.str("highest") == traffic_level_name(r.highest), "highest %s", traffic_level_name(r.highest));
    CHECK((int)r.aircraft_count == (int)e.num("aircraft_count"), "aircraft_count %d", r.aircraft_count);
    CHECK(e.str("summary") == sum, "summary '%s' want '%s'", sum, e.str("summary").c_str());
    CHECK(!forbidden(sum), "summary wording '%s'", sum);
    const std::vector<J>& want = e.get("alerts")->a;
    CHECK((int)r.n == (int)want.size(), "alert count %d want %d", r.n, (int)want.size());
    for (int i = 0; i < r.n && i < (int)want.size(); i++) {
      const TrafficAlert& a = r.alerts[i];
      const J& w = want[i];
      CHECK(w.str("level") == traffic_level_name(a.level), "#%d level %s", i, traffic_level_name(a.level));
      CHECK(w.str("kind") == traffic_kind_name(a.kind), "#%d kind %s", i, traffic_kind_name(a.kind));
      CHECK(w.str("drone") == a.drone_id, "#%d drone '%s'", i, a.drone_id);
      CHECK(w.str("hex") == a.hex, "#%d hex '%s'", i, a.hex);
      CHECK(w.str("text") == a.text, "#%d text '%s' want '%s'", i, a.text, w.str("text").c_str());
      CHECK(w.boolean("held") == a.held, "#%d held %d", i, a.held);
      CHECK(w.boolean("height_unknown") == a.height_unknown, "#%d height_unknown %d", i, a.height_unknown);
      CHECK(w.str("vert_rel") == traffic_vert_name(a.vert_rel), "#%d vert_rel %s", i, traffic_vert_name(a.vert_rel));
      CHECK(w.boolean("approx") == a.approx, "#%d approx %d", i, a.approx);
      CHECK(w.boolean("from_observer") == a.from_observer, "#%d from_observer %d", i, a.from_observer);
      CHECK(w.str("action") == a.action, "#%d action '%s' want '%s'", i, a.action, w.str("action").c_str());
      CHECK(w.str("resolution") == a.resolution, "#%d resolution '%s' want '%s'", i, a.resolution,
            w.str("resolution").c_str());
      CHECK(strstr(a.resolution, a.action) == a.resolution, "#%d resolution starts with the action", i);
      CHECK(!forbidden(a.resolution), "#%d resolution wording '%s'", i, a.resolution);
      CHECK(w.boolean("on_ground") == a.on_ground, "#%d on_ground %d", i, a.on_ground);
      CHECK(near_eq(a.horiz_m, w.get("horiz_m"), 1e-6), "#%d horiz %.9f", i, a.horiz_m);
      CHECK(near_eq(a.vert_m, w.get("vert_m"), 1e-6), "#%d vert %.9f", i, a.vert_m);
      CHECK(near_eq(a.bearing_deg, w.get("bearing_deg"), 1e-6), "#%d bearing %.9f", i, a.bearing_deg);
      CHECK(near_eq(a.cpa_s, w.get("cpa_s"), 1e-6), "#%d cpa %.9f", i, a.cpa_s);
      CHECK(near_eq(a.age_s, w.get("age_s"), 1e-9), "#%d age %.3f", i, a.age_s);
      CHECK(!forbidden(a.text), "#%d wording '%s'", i, a.text);
      if (a.ac_index >= 0) CHECK(!strcmp(ac[a.ac_index].hex, a.hex), "#%d ac_index", i);
      if (a.drone_index >= 0) CHECK(!strcmp(drones[a.drone_index].id, a.drone_id), "#%d drone_index", i);
      g_alerts++;
    }
    run_hand_checks(v, step, r);
    g_steps++;
  }
}

// ------------------------------------------------------------ host lines
static void traffic_reset_globals(void) {
  memset(g_traffic_ac, 0, sizeof(TrafficAircraft) * TRAFFIC_MAX_AIRCRAFT);
  g_traffic_count = 0; g_traffic_have = false; g_traffic_data_ms = 0; g_traffic_rx_ms = 0;
  g_traffic_unix_s = 0; g_traffic_partial = false;
  g_traffic_stage_open = false; g_traffic_stage_n = 0; g_traffic_stage_rx = 0;
  g_traffic_stage_t = 0; g_traffic_stage_age = 0;
  g_traffic_observer = {NAN, NAN, NAN};
  traffic_state_reset(&g_traffic_state);
}

static int g_cases = 0;

static void run_host_lines(const J& v) {
  uint32_t now = (uint32_t)v.num("now_ms");
  int k = 0;
  for (const J& c : v.get("cases")->a) {
    char ctx[64];
    snprintf(ctx, sizeof(ctx), "host_lines case %d", k++);
    g_ctx = ctx;
    traffic_reset_globals();
    g_traffic_observer = observer_of(c.get("observer"));
    const J& e = *c.get("expect");
    const std::vector<J>& lines = c.get("lines")->a;
    for (size_t i = 0; i < lines.size(); i++) {
      bool h = traffic_host_line(lines[i].s.c_str(), now);
      CHECK(h == e.get("handled")->a[i].b, "line %zu handled %d", i, h);
    }
    CHECK(g_traffic_have == e.boolean("have_data"), "have_data");
    CHECK(g_traffic_partial == e.boolean("partial"), "partial");
    CHECK((int)g_traffic_count == (int)e.num("count"), "count %d", g_traffic_count);
    if (g_traffic_have) CHECK(near_eq(traffic_age_s(g_traffic_data_ms, now), e.get("data_age_s"), 1e-9), "data age");
    const std::vector<J>& want = e.get("aircraft")->a;
    for (int i = 0; i < g_traffic_count && i < (int)want.size(); i++) {
      const TrafficAircraft& a = g_traffic_ac[i];
      const J& w = want[i];
      CHECK(w.str("hex") == a.hex, "#%d hex %s", i, a.hex);
      CHECK(w.str("callsign") == a.callsign, "#%d callsign '%s'", i, a.callsign);
      CHECK(w.str("type") == a.type, "#%d type '%s'", i, a.type);
      CHECK(near_eq(a.lat, w.get("lat"), 1e-12) && near_eq(a.lon, w.get("lon"), 1e-12), "#%d pos", i);
      CHECK(near_eq(a.alt_geom_m, w.get("alt_geom_m"), 1e-9), "#%d alt_geom", i);
      CHECK(near_eq(a.alt_baro_m, w.get("alt_baro_m"), 1e-9), "#%d alt_baro %.9f", i, a.alt_baro_m);
      CHECK(near_eq(a.gs_mps, w.get("gs_mps"), 1e-9), "#%d gs %.9f", i, a.gs_mps);
      CHECK(near_eq(a.track_deg, w.get("track_deg"), 1e-9), "#%d track", i);
      CHECK(near_eq(a.vs_mps, w.get("vs_mps"), 1e-9), "#%d vs %.9f", i, a.vs_mps);
      CHECK((int)a.squawk == (int)w.num("squawk"), "#%d squawk %d", i, a.squawk);
      CHECK(a.emergency == w.boolean("emergency"), "#%d emergency", i);
      CHECK(a.on_ground == w.boolean("on_ground"), "#%d on_ground", i);
      CHECK(near_eq(traffic_age_s(a.seen_ms, now), w.get("age_s"), 1e-9), "#%d age", i);
    }
    g_cases++;
  }
}

// ------------------------------------------------------------ C-only edges
static TrafficAircraft mk_ac(const char* hex, double lat, double lon, double alt, uint32_t seen) {
  TrafficAircraft a;
  memset(&a, 0, sizeof(a));
  snprintf(a.hex, sizeof(a.hex), "%s", hex);
  a.lat = lat; a.lon = lon; a.alt_geom_m = alt;
  a.alt_baro_m = a.gs_mps = a.track_deg = a.vs_mps = NAN;
  a.seen_ms = seen;
  return a;
}

static void test_edges(void) {
  g_ctx = "edges";
  // millis() wrap: a position stamped just before the wrap is 3 s old just after.
  CHECK(fabs(traffic_age_s(0xFFFFFC18u, 2000u) - 3.0) < 1e-9, "age across wrap");
  CHECK(traffic_age_s(5000, 4000) == 0.0, "future stamp -> age 0");

  // Old code: 52N 179.99E to 179.99W measured 24,643 km.
  double d = traffic_distance_m(52.0, 179.99, 52.0, -179.99);
  CHECK(d > 1300 && d < 1400, "antimeridian distance %.1f", d);

  // Capacity: 20 aircraft on the ground near a drone (cautions) + 1 airborne
  // (a warning) -> 16 kept, the warning first, then the 15 nearest cautions.
  TrafficState st; traffic_state_reset(&st);
  TrafficResult r;
  TrafficAircraft ac[21];
  uint32_t now = 500000;
  for (int i = 0; i < 20; i++) {
    char hx[8]; snprintf(hx, sizeof(hx), "e%05d", i);
    ac[i] = mk_ac(hx, 10.0005 + i * 0.0004, 20.0, NAN, now - 1000);
    ac[i].on_ground = true;
  }
  ac[20] = mk_ac("aaaaaa", 10.0, 20.009, 120, now - 1000);
  TrafficDrone dr; memset(&dr, 0, sizeof(dr));
  snprintf(dr.id, sizeof(dr.id), "DRONE1");
  dr.lat = 10.0; dr.lon = 20.0; dr.alt_geo_m = 100; dr.speed_mps = dr.heading_deg = NAN; dr.live = true;
  dr.height_m = NAN;
  traffic_evaluate(&dr, 1, ac, 21, true, now - 1000, now, &st, &r);
  CHECK(r.n == TRAFFIC_MAX_ALERTS, "capacity %d", r.n);
  CHECK(r.alerts[0].level == TRAFFIC_WARNING && !strcmp(r.alerts[0].hex, "aaaaaa"), "warning kept first");
  bool nearest = true;
  for (int i = 1; i < r.n; i++) {
    char hx[8]; snprintf(hx, sizeof(hx), "e%05d", i - 1);
    nearest &= !strcmp(r.alerts[i].hex, hx) && r.alerts[i].level == TRAFFIC_CAUTION;
  }
  CHECK(nearest, "then the 15 nearest cautions");
  char sum0[96]; traffic_summary(&r, sum0, sizeof(sum0));
  CHECK(!strcmp(sum0, "conflict watch on, 16 ADS-B conflicts, data 1 s old"), "summary %s", sum0);

  // The longest words still fit: a MAC-only drone, an aircraft below, a CPA.
  {
    TrafficState s2; traffic_state_reset(&s2);
    TrafficResult r2;
    TrafficDrone md = dr;
    snprintf(md.id, sizeof(md.id), "02:00:5E:7E:57:01");
    md.speed_mps = 0; md.heading_deg = 0; md.alt_geo_m = 400;
    TrafficAircraft lo = mk_ac("bbbbbb", 10.0, 20.0137, 260, now - 1000);   // ~1.5 km E, 140 m below
    lo.gs_mps = 60; lo.track_deg = 270;
    traffic_evaluate(&md, 1, &lo, 1, true, now - 1000, now, &s2, &r2);
    CHECK(r2.n == 1 && !strcmp(r2.alerts[0].resolution,
          "GIVE WAY: MOVE W, THEN LAND MAC 7E:57:01; AIRCRAFT 140 M BELOW, 1.5 KM E, CLOSEST IN 25 S"),
          "long resolution '%s'", r2.n ? r2.alerts[0].resolution : "");
    CHECK(r2.n == 1 && r2.alerts[0].vert_rel == TRAFFIC_VERT_BELOW, "below");
  }

  // traffic_ingest keeps the 32 nearest within 30 km, nearest first.
  traffic_reset_globals();
  g_traffic_observer = {0.0, 0.0, 0.0};
  static TrafficAircraft many[50];
  for (int i = 0; i < 50; i++) {
    char hx[8]; snprintf(hx, sizeof(hx), "%06x", 49 - i);
    many[i] = mk_ac(hx, (49 - i) * 0.001, 0.0, 500, now);
  }
  traffic_ingest(many, 50, now, now);
  CHECK(g_traffic_count == 32, "ingest cap %d", g_traffic_count);
  CHECK(!strcmp(g_traffic_ac[0].hex, "000000") && !strcmp(g_traffic_ac[31].hex, "00001f"), "ingest nearest first");

  // A hex sent twice installs once: its nearest copy (the same aircraft
  // would otherwise be two candidates writing over one alert entry).
  traffic_reset_globals();
  g_traffic_observer = {0.0, 0.0, 0.0};
  TrafficAircraft dup[3] = { mk_ac("abc001", 0.010, 0.0, 500, now), mk_ac("abc002", 0.008, 0.0, 500, now),
                             mk_ac("abc001", 0.005, 0.0, 500, now) };
  traffic_ingest(dup, 3, now, now);
  CHECK(g_traffic_count == 2 && !strcmp(g_traffic_ac[0].hex, "abc001") && fabs(g_traffic_ac[0].lat - 0.005) < 1e-12 &&
        !strcmp(g_traffic_ac[1].hex, "abc002"), "ingest: one entry per hex, its nearest copy (%d)", g_traffic_count);

  // "sq":true is not squawk 1 (the bool's 1 must not read as a code); em/gnd bools are flags.
  TrafficAircraft sq;
  CHECK(traffic_parse_aircraft("{\"hex\":\"abc003\",\"lat\":1,\"lon\":2,\"sq\":true,\"em\":true,\"gnd\":false,\"age_s\":1}",
                               now, &sq, nullptr) && sq.squawk == 0 && sq.emergency && !sq.on_ground,
        "parse: sq true -> 0, em true -> flag, gnd false -> airborne (squawk %d)", sq.squawk);
  CHECK(traffic_parse_aircraft("{\"hex\":\"abc004\",\"lat\":1,\"lon\":2,\"sq\":7700,\"age_s\":1}", now, &sq, nullptr) &&
        sq.squawk == 7700, "parse: a numeric squawk still reads");

  // traffic_tick: a set not refreshed for 10 min is no source.
  traffic_tick(nullptr, 0, now + 1000);
  CHECK(g_traffic_result.have_data && !g_traffic_result.stale, "tick fresh");
  traffic_tick(nullptr, 0, now + 31000);
  CHECK(g_traffic_result.stale, "tick stale after 31 s");
  traffic_tick(nullptr, 0, now + 601000);
  CHECK(!g_traffic_result.have_data, "tick no source after 10 min");
  char s[96]; traffic_summary(&g_traffic_result, s, sizeof(s));
  CHECK(!strcmp(s, "CONFLICT WATCH OFF: no ADS-B source"), "summary %s", s);

  // An over-long line is still bounded: 40 aircraft in one line keep 32.
  traffic_reset_globals();
  std::string line = "{\"cmd\":\"traffic\",\"t\":1,\"ac\":[";
  for (int i = 0; i < 40; i++) {
    char b[96]; snprintf(b, sizeof(b), "%s{\"hex\":\"%06x\",\"lat\":1.0,\"lon\":2.0,\"age_s\":1}", i ? "," : "", i);
    line += b;
  }
  line += "]}";
  CHECK(traffic_host_line(line.c_str(), now), "long line handled");
  CHECK(traffic_host_line("{\"cmd\":\"traffic_done\",\"n\":40}", now), "done handled");
  CHECK(g_traffic_count == 32 && !g_traffic_partial, "long line kept 32 (%d), not partial", g_traffic_count);
}

int main(int argc, char** argv) {
  const char* dir = argc > 1 ? argv[1] : "tests/vectors/traffic";
  DIR* dp = opendir(dir);
  if (!dp) { printf("FAIL cannot open %s\n", dir); return 1; }
  std::vector<std::string> files;
  while (struct dirent* de = readdir(dp)) {
    std::string n = de->d_name;
    if (n.size() > 5 && n.substr(n.size() - 5) == ".json") files.push_back(n);
  }
  closedir(dp);
  std::sort(files.begin(), files.end());
  int rule_files = 0;
  for (auto& f : files) {
    std::string path = std::string(dir) + "/" + f;
    FILE* fp = fopen(path.c_str(), "rb");
    std::string text;
    char buf[4096]; size_t n;
    while (fp && (n = fread(buf, 1, sizeof(buf), fp)) > 0) text.append(buf, n);
    if (fp) fclose(fp);
    J v;
    g_ctx = f;
    CHECK(jparse(text.c_str(), v) != nullptr && v.t == J::OBJ, "parse %s", f.c_str());
    if (v.has("cases")) run_host_lines(v);
    else if (v.has("steps")) { run_rule_vector(v); rule_files++; }
    else CHECK(false, "unknown vector shape");
  }
  g_ctx = "totals";
  CHECK(files.size() >= 16, "vector files %zu", files.size());
  CHECK(rule_files >= 15 && g_steps >= 60 && g_alerts >= 180 && g_cases >= 9 && g_hand >= 40,
        "coverage: %d rule files, %d steps, %d alerts, %d host cases, %d hand checks", rule_files, g_steps, g_alerts, g_cases, g_hand);
  test_edges();
  printf("traffic: %zu vector files, %d steps, %d alerts, %d hand checks, %d host cases, %d checks, %d failures\n",
         files.size(), g_steps, g_alerts, g_hand, g_cases, g_checks, g_fails);
  return g_fails ? 1 : 0;
}
