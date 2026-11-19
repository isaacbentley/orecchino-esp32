(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const make = (tag, classes, value) => {
    const element = document.createElement(tag);
    if (classes) element.className = classes;
    if (value !== undefined && value !== null) element.textContent = value;
    return element;
  };
  const integer = new Intl.NumberFormat("nl-BE", {maximumFractionDigits: 0});
  const decimal = new Intl.NumberFormat("nl-BE", {maximumFractionDigits: 1});
  const datetime = new Intl.DateTimeFormat("nl-BE", {dateStyle: "medium", timeStyle: "medium"});
  const colors = ["#7de0c1", "#77c6ff", "#d8adfa", "#ffba78", "#ef95a2", "#b5d98a", "#afd1eb"];
  const receiverLabels = {
    disconnected: ["Geen ontvanger", "Geen ontvanger verbonden", "Sluit een Orecchino-ontvanger aan via USB of start de simulatie."],
    searching: ["Ontvanger zoeken", "Ontvanger zoeken", "Sluit een Orecchino-ontvanger aan via USB of kies een COM-poort."],
    waiting: ["Wachten op gegevens", "Wachten op gegevens", "De COM-poort is geopend. De app wacht op gegevens van de ontvanger."],
    receiving: ["Ontvanger actief", "Geen drones waargenomen", "De ontvanger luistert naar Remote ID-uitzendingen."],
    stalled: ["Signaal onderbroken", "Ontvanger reageert niet", "De app probeert opnieuw te verbinden. Controleer de USB-kabel als dit aanhoudt."],
  };
  const map = L.map("map", {zoomControl: false, attributionControl: false, preferCanvas: true, minZoom: 2, maxZoom: 20}).setView([50.85, 4.35], 7);
  L.control.zoom({position: "bottomright", zoomInTitle: "Inzoomen", zoomOutTitle: "Uitzoomen"}).addTo(map);
  L.control.scale({position: "bottomleft", metric: true, imperial: false}).addTo(map);
  L.control.attribution({prefix: false}).addTo(map);
  const esriCanvas = "https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/";
  L.tileLayer(esriCanvas + "World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}", {
    attribution: '<a href="https://www.esri.com/" target="_blank" rel="noopener noreferrer">Esri</a>, HERE, Garmin, <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">&copy; OpenStreetMap</a>, GIS User Community',
  }).addTo(map);
  L.tileLayer(esriCanvas + "World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}", {zIndex: 2}).addTo(map);
  const zoneLayer = L.layerGroup().addTo(map);
  const droneguideLayer = L.featureGroup().addTo(map);
  const trackLayer = L.layerGroup().addTo(map);
  let selectedId = null;
  let activeTab = "live";
  let technicalOpen = false;
  let positioned = false;
  let drawnZones = -1;
  let airspaceRevision = null;
  let liveKey = "";
  let layerKey = "";
  let scrollToDetail = false;
  let state = {receiver: {status: "searching", tracks: []}, settings: {}};
  let airspace = {alerts: [], zones: [], trafficEnabled: true, radiusKm: 10};
  let droneguide = {state: "loading", zones: []};
  let droneguideVisible = true;
  let droneguideDrawn = "";
  let droneguideRequest = 0;
  let tilePlanInput = null;
  let tileState = {phase: "idle"};
  let tilesUpdating = false;
  let receiverRequest = 0;
  let airspaceRequest = 0;
  let atak = null;
  let atakRequest = 0;
  let atakDraftChanged = false;

  async function api(path, body) {
    const options = {cache: "no-store"};
    if (body !== undefined) {
      options.method = "POST";
      options.headers = {"Content-Type": "application/json"};
      options.body = body instanceof Blob ? body : JSON.stringify(body);
    }
    const response = await fetch(path, options);
    if (response.status === 204) return {};
    const raw = await response.text();
    let value;
    try {
      value = JSON.parse(raw);
    } catch {
      if (!response.ok && response.headers.get("Content-Type")?.startsWith("text/plain")) throw new Error(raw.trim());
      throw new Error("De app heeft een ongeldig antwoord ontvangen.");
    }
    if (!response.ok) throw new Error(value.error || `Verzoek mislukt (${response.status}).`);
    return value;
  }

  function message(target, value = "", isError = false) {
    target.textContent = value;
    target.classList.toggle("error", isError);
    target.hidden = !value;
  }

  async function action(button, feedback, job) {
    if (button.getAttribute("aria-busy") === "true") return;
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
    message(feedback);
    try {
      await job();
    } catch (error) {
      message(feedback, error.message, true);
    } finally {
      button.removeAttribute("aria-busy");
      button.disabled = false;
      updateActionAvailability();
    }
  }

  function coordinate(lat, lon) {
    return Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180 ? [lat, lon] : null;
  }

  function point(value) {
    return value ? coordinate(value.lat, value.lon) : null;
  }

  function location() {
    return point(state.settings);
  }

  function distance(first, second) {
    if (!first || !second) return null;
    return L.latLng(...first).distanceTo(L.latLng(...second));
  }

  function metric(value, unit, format = decimal) {
    return Number.isFinite(value) ? `${format.format(value)} ${unit}` : "–";
  }

  function range(value) {
    if (!Number.isFinite(value)) return "–";
    return value >= 1000 ? metric(value / 1000, "km") : metric(value, "m", integer);
  }

  function lastSeen(age) {
    if (!Number.isFinite(age)) return "Onbekend";
    if (age < 2) return "Zojuist";
    if (age < 60) return `${Math.floor(age)} s geleden`;
    if (age < 3600) return `${Math.floor(age / 60)} min geleden`;
    return `${Math.floor(age / 3600)} u geleden`;
  }

  function labelOr(value) {
    return value === undefined || value === null || value === "" ? "–" : String(value);
  }

  function color(track) {
    return colors[Math.abs(Number(track.colorIndex) || 0) % colors.length] || colors[0];
  }

  function getTrack(id) {
    return (state.receiver.tracks || []).find((track) => track.id === id);
  }

  function trackTitle(track) {
    return track.model || track.title || track.uasId || track.id;
  }

  function heightSuffix(track) {
    return track.heightRef === 1 ? "m AGL" : track.heightRef === 0 ? "m boven startpunt" : "m";
  }

  function badge(label, kind) {
    return make("span", `badge ${kind}`, label);
  }

  function trafficAlert(track) {
    return (airspace.alerts || []).find((alert) => alert.droneId === track.id);
  }

  function trackBadges(track) {
    const badges = make("div", "badges");
    if (track.status === 3) badges.append(badge("NOODSTATUS GEMELD", "danger"));
    if (track.authState === "invalid") badges.append(badge("ONGELDIGE ID-HANDTEKENING", "danger"));
    const alert = trafficAlert(track);
    if (alert) badges.append(badge("VERKEERSWAARSCHUWING", alert.level === "warning" ? "danger" : "amber"));
    if (track.simulated) badges.append(badge("GESIMULEERD", "amber"));
    if (track.stale) badges.append(badge("GEEN RECENT SIGNAAL", "dim"));
    if (track.authState === "test_key") badges.append(badge("TESTSLEUTEL", "dim"));
    const tfr = (airspace.trackTfrs || {})[track.id] || (track.inTfr && track.tfrId);
    if (tfr) badges.append(badge("FAA · " + tfr, "amber"));
    return badges;
  }

  function contactCard(track) {
    const card = make("button", "contact-card");
    card.type = "button";
    card.dataset.trackId = track.id;
    card.style.setProperty("--track-color", color(track));
    card.setAttribute("aria-pressed", String(track.id === selectedId));
    const top = make("div", "contact-row");
    const age = make("span", "contact-age", lastSeen(track.ageSeconds));
    age.dataset.ageId = track.id;
    top.append(make("strong", "", trackTitle(track)), age);
    card.append(top);
    const identifying = track.title || track.uasId;
    if (identifying && identifying !== trackTitle(track)) card.append(make("span", "contact-id", identifying));
    const meta = make("div", "contact-meta");
    if (Number.isFinite(track.height)) meta.append(make("span", "", metric(track.height, heightSuffix(track))));
    const receiverRange = distance(location(), point(track));
    if (receiverRange !== null) meta.append(make("span", "", range(receiverRange)));
    if (Number.isFinite(track.rssi)) meta.append(make("span", "", metric(track.rssi, "dBm", integer)));
    if (meta.childElementCount) card.append(meta);
    const badges = trackBadges(track);
    if (badges.childElementCount) card.append(badges);
    card.addEventListener("click", () => selectTrack(track.id, true, true));
    return card;
  }

  function metricGrid(pairs) {
    const grid = make("dl", "metrics");
    for (const [label, value] of pairs) {
      const cell = make("div", "metric");
      cell.append(make("dt", "", label), make("dd", "", labelOr(value)));
      grid.append(cell);
    }
    return grid;
  }

  function alertCard(alert) {
    const card = make("article", `alert-card ${alert.level === "warning" ? "warning" : ""}`);
    const title = make("h3", "", alert.action || "Verkeer in de buurt");
    card.append(title);
    const callSign = alert.aircraft?.callsign || alert.aircraft?.id;
    const numbers = [
      Number.isFinite(alert.horizontalM) && "horizontaal " + range(alert.horizontalM),
      Number.isFinite(alert.verticalM) && "verticaal " + range(alert.verticalM),
    ].filter(Boolean);
    if (numbers.length || callSign) {
      const facts = make("p", "", [callSign, ...numbers].filter(Boolean).join(" · "));
      facts.dataset.alertAgeId = alert.id;
      facts.dataset.alertFacts = facts.textContent;
      card.append(facts);
    }
    if (alert.summary) card.append(make("p", "", alert.summary));
    if (alert.detail) card.append(make("p", "", alert.detail));
    if (alert.held) card.append(make("span", "badge dim", "EERDERE WAARSCHUWING"));
    if (alert.simulated) card.append(badge("GESIMULEERD", "amber"));
    const show = make("button", "button", "Toon op kaart");
    show.type = "button";
    show.disabled = !(point(alert.origin) || point(alert.aircraft?.coordinate));
    show.addEventListener("click", () => showAlert(alert));
    card.append(show);
    return card;
  }

  function renderTrackDetails(track) {
    const container = $("detail-section");
    container.hidden = !track;
    if (!track) {
      container.replaceChildren();
      return;
    }
    const header = make("div", "detail-title");
    const headings = make("div");
    headings.append(make("h2", "", trackTitle(track)));
    const identifying = track.title || track.uasId;
    if (identifying && identifying !== trackTitle(track)) headings.append(make("p", "contact-id", identifying));
    const close = make("button", "button icon", "×");
    close.type = "button";
    close.setAttribute("aria-label", "Contact sluiten");
    close.addEventListener("click", () => selectTrack(null));
    header.append(headings, close);
    const receiverRange = distance(location(), point(track));
    const vital = metricGrid([
      ["Laatst gehoord", lastSeen(track.ageSeconds)],
      ["Afstand tot ontvanger", range(receiverRange)],
      ["Hoogte", metric(track.height, heightSuffix(track))],
      ["Snelheid", metric(track.speed, "m/s")],
      ["Afstand drone–operator", range(track.operatorDistance)],
      ["Koers", metric(track.heading, "°", integer)],
    ]);
    vital.querySelector("dd").dataset.ageId = track.id;
    const children = [header];
    const badges = trackBadges(track);
    if (badges.childElementCount) children.push(badges);
    children.push(vital);
    if (track.operatorImplausible) children.push(make("p", "detail-notes", "Gemelde operatorpositie ligt meer dan 15 km van de drone."));
    if (track.ssidMismatch) children.push(make("p", "detail-notes", "De Wi-Fi-SSID noemt een ander serienummer dan de uitgezonden Basic ID."));
    const alert = trafficAlert(track);
    if (alert) children.push(alertCard(alert));
    const technical = make("details");
    technical.open = technicalOpen;
    technical.addEventListener("toggle", () => {
      if (technical.isConnected) technicalOpen = technical.open;
    });
    technical.append(make("summary", "", "Technische gegevens"), metricGrid([
      ["Fabrikant", track.manufacturer], ["Remote ID", track.uasId],
      ["Uitgezonden operator-ID", track.operatorId], ["Beschrijving", track.selfDesc],
      ["MAC-adressen", track.macs?.join(", ")], ["Transporten", track.sources?.join(", ")],
      ["Signaalsterkte", metric(track.rssi, "dBm", integer)], ["Kanaal", track.channel],
      ["Berichten", track.msgCount], ["Remote ID-decodering", track.evidence],
      ["Formaat", track.format], ["Radio", track.phy],
      ["SSID", track.ssid], ["Authenticatie", track.authState],
      ["Geometrische hoogte", metric(track.altGeo, "m")], ["Barometrische hoogte", metric(track.altBaro, "m")],
      ["Verticale snelheid", metric(track.vspeed, "m/s")], ["Operatorhoogte", metric(track.operatorAlt, "m")],
    ]));
    children.push(technical);
    container.replaceChildren(...children);
  }

  function redrawLive() {
    const tracks = state.receiver.tracks || [];
    const alerts = airspace.alerts || [];
    if (selectedId && !getTrack(selectedId)) {
      selectedId = null;
      technicalOpen = false;
    }
    const trackKeys = tracks.map((track) => {
      const {trail, ageSeconds, firstSeen, lastSeen: seen, ...visible} = track;
      return visible;
    });
    const alertsKey = alerts.map(({dataAgeSec, ...alert}) => alert);
    const key = JSON.stringify([trackKeys, alertsKey, airspace.trackTfrs, selectedId, location()]);
    const focus = document.activeElement;
    const focusTrack = focus?.dataset.trackId;
    const focusDetail = focus?.closest("#detail-section");
    if (key !== liveKey || scrollToDetail) {
      liveKey = key;
      if (!focusDetail || scrollToDetail) {
        $("alert-list").replaceChildren(...alerts.map(alertCard));
        $("contact-list").replaceChildren(...tracks.map(contactCard));
        renderTrackDetails(getTrack(selectedId));
        if (focusTrack) {
          [...$("contact-list").children].find((item) => item.dataset.trackId === focusTrack)?.focus({preventScroll: true});
        }
      } else {
        liveKey = "";
      }
    }
    for (const item of document.querySelectorAll("[data-age-id]")) {
      const track = getTrack(item.dataset.ageId);
      if (track) item.textContent = lastSeen(track.ageSeconds);
    }
    for (const item of document.querySelectorAll("[data-alert-age-id]")) {
      const alert = alerts.find((entry) => entry.id === item.dataset.alertAgeId);
      const age = alert && Number.isFinite(alert.dataAgeSec) ? "data " + metric(alert.dataAgeSec, "s", integer) + " oud" : "";
      item.textContent = [item.dataset.alertFacts, age].filter(Boolean).join(" · ");
    }
    const totalActive = tracks.filter((track) => !track.stale).length;
    const simulated = tracks.filter((track) => track.simulated && !track.stale).length;
    $("live-tab-count").textContent = integer.format(totalActive);
    $("contact-count").textContent = `${integer.format(totalActive)} actief${simulated ? ` · ${simulated} gesimuleerd` : ""}`;
    $("alert-count").textContent = integer.format(alerts.length);
    $("alerts-section").hidden = !alerts.length;
    $("empty-contacts").hidden = Boolean(tracks.length);
    if (scrollToDetail && selectedId) {
      scrollToDetail = false;
      $("detail-section").scrollIntoView({block: "nearest", behavior: "smooth"});
    }
  }

  function mapIcon(kind, trackColor, heading = null, textValue = "", selected = false, stale = false) {
    const symbol = make("span", `map-symbol ${kind}${selected ? " selected" : ""}${stale ? " stale" : ""}`);
    symbol.style.setProperty("--track-color", trackColor);
    const shape = kind === "aircraft" ? "aircraft-arrow" : Number.isFinite(heading) ? "heading-arrow" : "position-dot";
    const part = make("span", textValue ? "marker-text" : shape, textValue);
    if (heading !== null && Number.isFinite(heading) && !textValue) part.style.transform = `rotate(${heading}deg)`;
    symbol.append(part);
    const size = kind === "operator" ? 18 : kind === "observer" ? 19 : 28;
    return L.divIcon({className: "map-pin", html: symbol, iconSize: [size, size], iconAnchor: [size / 2, size / 2]});
  }

  function mapTag(title, annotation = "") {
    const tag = make("span", "map-tag", title);
    if (annotation) tag.append(make("small", "", annotation));
    return tag;
  }

  function mapCoordinate(position, reference = map.getCenter().lng) {
    const lon = position[1] - 360 * Math.round((position[1] - reference) / 360);
    return [position[0], lon];
  }

  function zoneShape(zone) {
    const coordinates = (zone.ring || []).map(point).filter(Boolean);
    if (coordinates.length < 3) return;
    const anchor = mapCoordinate(coordinates[0])[1];
    const polygon = L.polygon(coordinates.map((position) => mapCoordinate(position, anchor)), {
      color: "#f1a958", fillColor: "#bc7032", weight: 1.25, dashArray: "4 3", fillOpacity: .13,
    }).addTo(zoneLayer);
    const label = make("div", "zone-popup");
    label.append(make("strong", "", zone.notam || zone.id || "FAA-beperking"));
    if (zone.title) label.append(make("p", "", zone.title));
    if (zone.legal) label.append(make("p", "", zone.legal));
    polygon.bindPopup(label);
  }

  function renderZones() {
    const paneWorld = Math.round(map.getCenter().lng / 360);
    const key = JSON.stringify([airspaceRevision, paneWorld]);
    if (drawnZones === key) return;
    drawnZones = key;
    zoneLayer.clearLayers();
    for (const zone of airspace.zones || []) zoneShape(zone);
  }

  function droneguideDate(value) {
    if (!value) return "";
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? datetime.format(date) : value;
  }

  function droneguideAltitude(value, unit, reference) {
    if (!Number.isFinite(value)) return "";
    const units = {F: "ft", FT: "ft", M: "m"};
    return [decimal.format(value), units[unit] || unit, reference].filter(Boolean).join(" ");
  }

  function droneguidePopup(zone) {
    const content = make("div", "droneguide-popup");
    content.append(make("strong", "", zone.name || zone.id));
    const list = make("dl");
    const row = (label, value) => {
      if (value) list.append(make("dt", "", label), make("dd", "", value));
    };
    const restrictions = {PROHIBITED: "Verboden", REQ_AUTHORISATION: "Toestemming vereist", CONDITIONAL: "Voorwaardelijk"};
    row("Zonecode", zone.id);
    row("Beperking volgens bron", restrictions[zone.restriction] || zone.restriction);
    row("Ondergrens", droneguideAltitude(zone.lower, zone.lowerUnit || zone.unit, zone.lowerReference));
    row("Bovengrens", droneguideAltitude(zone.upper, zone.upperUnit || zone.unit, zone.upperReference));
    row("Geldig vanaf", droneguideDate(zone.validFrom));
    row("Geldig tot", droneguideDate(zone.validUntil));
    row("Tijdschema volgens export", zone.schedule);
    const activities = {active: "Actief", inactive: "Inactief", unknown: "Onbekend"};
    if (typeof zone.activeAtSnapshot === "boolean" && droneguide.snapshotAt) {
      const status = zone.activeAtSnapshot ? "Actief" : "Inactief";
      row("Bij API-opname", `${status} · ${droneguideDate(droneguide.snapshotAt)}`);
      if (droneguide.stale) row("Activiteit", "Onbekend · verouderde opname");
    } else {
      row("Activiteit", activities[zone.activity] || activities.unknown);
    }
    row("Reden", zone.reason);
    row("Voorwaarden", (zone.conditions || []).join("\n"));
    row("Zonebeheer", (zone.authorities || []).map(({name, service}) => name || service).filter(Boolean).join(", "));
    row("Toelichting", zone.message);
    content.append(list);
    const source = make("a", "", "Actuele informatie op Droneguide (skeyes)");
    source.href = "https://map.droneguide.be/";
    source.target = "_blank";
    source.rel = "noopener noreferrer";
    content.append(source);
    return content;
  }

  function renderDroneguideZones() {
    const key = JSON.stringify([droneguide.revision, droneguide.activityRevision, droneguide.activeOnly, Math.round(map.getCenter().lng / 360)]);
    if (droneguideDrawn === key) return;
    droneguideDrawn = key;
    droneguideLayer.clearLayers();
    for (const zone of droneguide.zones || []) {
      if (droneguide.activeOnly && zone.activity !== "active") continue;
      const style = {color: "#c6b8ff", fillColor: "#ab92ff", weight: 1.3, fillOpacity: .16};
      if (zone.activity === "inactive") Object.assign(style, {opacity: .55, fillOpacity: .07, dashArray: "4 4"});
      if (zone.activity === "unknown") Object.assign(style, {opacity: .7, fillOpacity: .09, dashArray: "2 4"});
      const center = point(zone.circle?.center);
      if (center && Number.isFinite(zone.circle.radiusM) && zone.circle.radiusM > 0) {
        L.circle(mapCoordinate(center), {...style, radius: zone.circle.radiusM})
          .bindPopup(() => droneguidePopup(zone)).addTo(droneguideLayer);
        continue;
      }
      const polygons = (zone.polygons || []).map((polygon) => {
        const rings = polygon.map((ring) => ring.map(point).filter(Boolean));
        if (!rings.length || rings[0].length < 3) return null;
        const anchor = mapCoordinate(rings[0][0])[1];
        return rings.filter((ring) => ring.length >= 3).map((ring) => ring.map((position) => mapCoordinate(position, anchor)));
      }).filter(Boolean);
      if (polygons.length) L.polygon(polygons, style).bindPopup(() => droneguidePopup(zone)).addTo(droneguideLayer);
    }
  }

  function renderDroneguideStatus() {
    const hasZones = (droneguide.zones || []).length > 0;
    const hasSnapshot = Boolean(droneguide.updatedAt);
    const live = Boolean(droneguide.liveEnabled);
    const fromAPI = droneguide.sourceType === "live";
    const activeOnly = Boolean(droneguide.activeOnly);
    const hasVisibleZones = hasZones && (!activeOnly || droneguide.activeCount > 0);
    const shown = hasVisibleZones && droneguideVisible;
    if (shown && !map.hasLayer(droneguideLayer)) map.addLayer(droneguideLayer);
    else if (!shown && map.hasLayer(droneguideLayer)) map.removeLayer(droneguideLayer);
    const toggle = $("droneguide-toggle");
    if (hasZones) toggle.setAttribute("aria-pressed", String(droneguideVisible));
    else toggle.removeAttribute("aria-pressed");
    toggle.title = hasZones ? "Belgische geozones tonen of verbergen" : "Belgische geozones beheren";
    $("droneguide-legend").hidden = !shown;
    $("droneguide-fit").disabled = !hasVisibleZones;
    $("droneguide-active-only").setAttribute("aria-checked", String(activeOnly));
    $("droneguide-live").setAttribute("aria-pressed", String(live));
    $("droneguide-refresh").disabled = !live || droneguide.state === "loading" || $("droneguide-refresh").getAttribute("aria-busy") === "true";
    const count = integer.format(droneguide.count || 0);
    const zones = `${count} ${droneguide.count === 1 ? "kaartzone" : "kaartzones"}`;
    const activeCount = droneguide.activeCount || 0;
    const activeZones = `${integer.format(activeCount)} actieve ${activeCount === 1 ? "zone" : "zones"}`;
    const loaded = droneguideDate(droneguide.updatedAt);
    const source = fromAPI ? "via API" : "uit export";
    let summary = live ? "Bezig met ophalen…" : "Belgische geozones instellen";
    if (hasZones && !droneguideVisible) summary = "Belgische geozones verborgen";
    else if (hasZones && activeOnly && fromAPI && droneguide.stale) summary = "Geen actuele activiteitsgegevens";
    else if (hasZones && activeOnly && activeCount === 0) summary = "Geen bevestigde actieve zones";
    else if (shown) summary = `${activeOnly ? activeZones : zones} · ${source}`;
    else if (droneguide.state === "loading") summary = "Belgische geozones laden…";
    else if (hasSnapshot) summary = "0 zones tot 500 ft AGL";
    if (live && droneguide.state === "error") summary = hasZones ? `${summary} · vernieuwen mislukt` : "Droneguide-verzoek mislukt";
    else if (shown && fromAPI && droneguide.stale) summary = `${zones} · opgeslagen API-opname`;
    let status = hasSnapshot ? `${zones} tot 500 ft AGL · ${source}${loaded ? ` · ${loaded}` : ""}.` : "Er zijn nog geen geozones ingelezen.";
    if (hasSnapshot && activeOnly) status += ` ${activeZones} in deze weergave.`;
    if (droneguide.snapshotAt) {
      status += ` Activiteitsopname: ${droneguideDate(droneguide.snapshotAt)}.`;
      if (droneguide.stale) status += " De activiteitsopname is verouderd.";
    }
    if (droneguide.unknownActivityCount > 0) {
      status += ` Activiteit onbekend bij ${integer.format(droneguide.unknownActivityCount)} ${droneguide.unknownActivityCount === 1 ? "zone" : "zones"}.`;
    }
    if (droneguide.omittedCount > 0) status += ` Zones zonder tekenbare geometrie: ${integer.format(droneguide.omittedCount)}.`;
    if (droneguide.unknownAltitudeCount > 0) {
      const amount = integer.format(droneguide.unknownAltitudeCount);
      status += ` Onbepaalde AGL-hoogte bij ${amount} ${droneguide.unknownAltitudeCount === 1 ? "zone" : "zones"} buiten de selectie.`;
    }
    if (live && droneguide.state === "loading") status = `Droneguide ophalen… ${hasSnapshot ? status : ""}`;
    if (fromAPI && !live && hasSnapshot) status += " Automatisch ophalen staat uit.";
    if (droneguide.error) status = `${droneguide.error}${hasSnapshot ? ` Laatste gegevens: ${status}` : ""}`;
    $("droneguide-summary").textContent = summary;
    $("droneguide-status").textContent = status;
    $("droneguide-status").classList.toggle("error", droneguide.state === "error");
  }

  async function loadDroneguide() {
    const request = ++droneguideRequest;
    let view = await api("/api/droneguide?zones=0");
    if (request !== droneguideRequest) return;
    if (view.revision !== droneguide.revision || view.activityRevision !== droneguide.activityRevision) {
      view = await api("/api/droneguide");
      if (request !== droneguideRequest) return;
    } else {
      view.zones = droneguide.zones;
    }
    droneguide = view;
    renderDroneguideZones();
    renderDroneguideStatus();
  }

  function showAlert(alert) {
    const positions = [point(alert.origin), point(alert.aircraft?.coordinate)].filter(Boolean);
    if (alert.droneId && getTrack(alert.droneId)) selectTrack(alert.droneId, false, true);
    fitPositions(positions, 15);
  }

  function labelCollides(point, occupied) {
    return occupied.some((other) => Math.abs(point.x - other.x) < 120 && Math.abs(point.y - other.y) < 32);
  }

  function renderMap() {
    renderZones();
    renderDroneguideZones();
    const center = map.getCenter();
    const tracks = (state.receiver.tracks || []).filter((track) => point(track));
    const alerts = airspace.alerts || [];
    const key = JSON.stringify([
      tracks.map(({ageSeconds, firstSeen, lastSeen: seen, msgCount, ...track}) => track),
      alerts.map(({dataAgeSec, ...alert}) => alert), selectedId, location(), center.lat, center.lng, map.getZoom(),
    ]);
    if (layerKey === key) return;
    layerKey = key;
    trackLayer.clearLayers();
    const home = location();
    if (home) {
      L.marker(mapCoordinate(home), {icon: mapIcon("observer", "#77c6ff"), title: "Ontvangerlocatie", alt: "Ontvangerlocatie", zIndexOffset: -150})
        .bindTooltip(mapTag("Ontvangerlocatie"), {direction: "right", offset: [10, 0]}).addTo(trackLayer);
    }
    const sorted = [...tracks].sort((a,b) => {
      const priority = (track) => Number(track.id === selectedId) * 8 + Number(track.status === 3 || track.authState === "invalid" || Boolean(trafficAlert(track))) * 4 + Number(!track.stale);
      return priority(b) - priority(a);
    });
    const occupied = [];
    for (const track of sorted) {
      const position = mapCoordinate(point(track));
      const trackColor = color(track);
      const selected = selectedId === track.id;
      const emergency = track.status === 3;
      const invalid = track.authState === "invalid";
      const alerting = emergency || invalid || Boolean(trafficAlert(track));
      const trail = (track.trail || []).map(point).filter(Boolean).map((entry) => mapCoordinate(entry, position[1]));
      if (trail.length > 1) {
        L.polyline(trail, {color: trackColor, opacity: track.stale ? .28 : .79, weight: selected ? 3 : 2, interactive: false}).addTo(trackLayer);
      }
      const operator = coordinate(track.operatorLat, track.operatorLon);
      if (operator) {
        const opPosition = mapCoordinate(operator, position[1]);
        const operatorLabel = track.operatorImplausible ? "Gemelde operatorpositie · onwaarschijnlijke afstand" : "Operator · " + trackTitle(track);
        L.marker(opPosition, {
          icon: mapIcon("operator", trackColor, null, "", false, track.stale),
          title: operatorLabel, alt: operatorLabel, zIndexOffset: -100,
        }).bindTooltip(mapTag(operatorLabel), {direction: "right", offset: [10, 0]}).addTo(trackLayer)
          .on("click", () => selectTrack(track.id, false, true));
        L.polyline([position, opPosition], {color: trackColor, weight: 1, opacity: track.operatorImplausible ? .23 : .42, dashArray: "3 5", interactive: false}).addTo(trackLayer);
      }
      const title = trackTitle(track);
      const annotations = [
        emergency && "NOODSTATUS GEMELD", invalid && "ONGELDIGE ID-HANDTEKENING", Boolean(trafficAlert(track)) && "VERKEERSWAARSCHUWING", track.simulated && "GESIMULEERD",
      ].filter(Boolean);
      const marker = L.marker(position, {
        title: [title, ...annotations].join(" · "), alt: [title, ...annotations].join(" · "),
        icon: mapIcon(emergency ? "warning" : invalid ? "invalid" : "", trackColor, track.heading, emergency ? "!" : invalid ? "×" : "", selected, track.stale),
        zIndexOffset: selected ? 900 : alerting ? 700 : 0,
      }).addTo(trackLayer);
      marker.on("click", () => selectTrack(track.id, false, true));
      const screenPoint = map.latLngToLayerPoint(position);
      const permanent = selected || alerting || track.simulated || (!track.stale && !labelCollides(screenPoint, occupied));
      if (permanent) occupied.push(screenPoint);
      marker.bindTooltip(mapTag(title, annotations.join(" · ")), {permanent, direction: "right", offset: [14, 0], opacity: track.stale ? .75 : 1});
    }
    for (const alert of alerts) {
      const aircraft = point(alert.aircraft?.coordinate);
      const projection = point(alert.aircraft?.projection);
      const origin = point(alert.origin);
      if (!aircraft) continue;
      const position = mapCoordinate(aircraft);
      const severity = alert.level === "warning" ? "#ff9b93" : "#ffc079";
      const title = alert.aircraft.callsign || alert.aircraft.id || "Verkeer";
      const annotation = alert.simulated ? "GESIMULEERD" : "";
      const from = projection && mapCoordinate(projection, position[1]);
      let bearing = Number(alert.aircraft.heading);
      if (!Number.isFinite(bearing) && from) {
        bearing = Math.atan2((from[1] - position[1]) * Math.cos(position[0] * Math.PI / 180), from[0] - position[0]) * 180 / Math.PI;
      }
      L.marker(position, {icon: mapIcon("aircraft", severity, bearing), title, alt: title, zIndexOffset: 800}).addTo(trackLayer)
        .bindTooltip(mapTag(title, annotation), {permanent: true, direction: "top", offset: [0, -14]})
        .on("click", () => showAlert(alert));
      if (origin) {
        const bridge = L.polyline([mapCoordinate(origin, position[1]), position], {color: severity, weight: 1.5, opacity: .85, dashArray: "4 5"}).addTo(trackLayer);
        bridge.bindTooltip(mapTag(range(alert.horizontalM) + " horizontaal · " + range(alert.verticalM) + " verticaal"), {sticky: true});
      }
      if (from) L.polyline([position, from], {color: severity, weight: 2, opacity: .8, dashArray: "5 7", interactive: false}).addTo(trackLayer);
    }
  }

  function fitPositions(positions, maxZoom = 16) {
    if (!positions.length) return;
    const reference = mapCoordinate(positions[0])[1];
    const coordinates = positions.map((position) => mapCoordinate(position, reference));
    if (coordinates.length === 1 && map.getZoom() >= maxZoom - 2) {
      map.panTo(coordinates[0]);
    } else {
      map.fitBounds(coordinates, {paddingTopLeft: [40, 100], paddingBottomRight: [55, 70], maxZoom});
    }
  }

  function fitAll() {
    const positions = (state.receiver.tracks || []).flatMap((track) => [point(track), coordinate(track.operatorLat, track.operatorLon)]).filter(Boolean);
    if (positions.length) fitPositions(positions);
    else if (location()) fitPositions([location()], 13);
  }

  function selectTrack(id, recenter = false, showDetail = false) {
    if (selectedId !== id) technicalOpen = false;
    selectedId = id;
    if (id && activeTab !== "live") pickTab("live");
    scrollToDetail = Boolean(id && showDetail);
    redrawLive();
    renderMap();
    const track = getTrack(id);
    if (recenter && track) fitPositions([point(track), coordinate(track.operatorLat, track.operatorLon)].filter(Boolean), 16);
  }

  function renderReceiver() {
    const receiver = state.receiver;
    const labels = receiverLabels[receiver.status] || receiverLabels.disconnected;
    $("receiver-control").dataset.status = receiver.status;
    $("receiver-label").textContent = [labels[0], receiver.port].filter(Boolean).join(" · ");
    $("empty-heading").textContent = labels[1];
    $("empty-description").textContent = labels[2];
    $("footer-device").dataset.status = receiver.status;
    $("footer-board").textContent = [receiver.board || "USB-ontvanger", receiver.firmware ? "v" + String(receiver.firmware).replace(/^v/, "") : ""].filter(Boolean).join(" · ");
    $("footer-stat").textContent = receiver.stats?.ridCount !== undefined ? `${integer.format(receiver.stats.ridCount)} RID` : (receiver.port || "");
    $("demo-button").setAttribute("aria-pressed", String(Boolean(receiver.demo)));
    $("simulation-banner").hidden = !receiver.demo;
    $("home-button").disabled = !location();
    if ($("settings-dialog").open && receiver.error && !($("port-message").classList.contains("error"))) {
      message($("port-message"), receiver.error, true);
    }
    redrawLive();
    if (!positioned && ((receiver.tracks || []).some(point) || location())) {
      positioned = true;
      fitAll();
    }
    renderMap();
    updateActionAvailability();
  }

  function translateTraffic() {
    const status = airspace.trafficStatus;
    if (airspace.trafficState === "loading") return "Wacht op ADS-B-gegevens";
    if (airspace.trafficState === "ready") {
      const age = airspace.trafficAgeSec;
      return Number.isFinite(age) ? "Verkeersbewaking actief · data " + metric(age, "s", integer) + " oud" : "Verkeersbewaking actief";
    }
    if (!status) return "Verkeersbewaking laden…";
    const lower = status.toLowerCase();
    if (lower.includes("simulat")) return "Gesimuleerde verkeersgegevens";
    if (lower.includes("off")) return "Verkeersbewaking uit";
    if (lower.includes("position")) return "Wacht op een ontvanger- of dronepositie";
    if (lower.includes("stale")) return "VERKEERSGEGEVENS VEROUDERD";
    if (lower.includes("fetch") && (lower.includes("fail") || lower.includes("error"))) return "ADS-B-gegevens ophalen mislukt";
    return status;
  }

  function renderAirspace() {
    $("traffic-toggle").setAttribute("aria-pressed", String(Boolean(airspace.trafficEnabled)));
    $("traffic-status").textContent = translateTraffic();
    const tfrStatus = {loading: "FAA-zones laden…", error: "FAA-zones ophalen mislukt", ready: `${integer.format(airspace.tfrCount ?? 0)} FAA-zones geladen`};
    $("tfr-status").textContent = tfrStatus[airspace.tfrState] || airspace.tfrStatus || tfrStatus.loading;
    redrawLive();
    renderMap();
  }

  async function loadReceiver() {
    const request = ++receiverRequest;
    const next = await api("/api/state");
    if (request !== receiverRequest) return;
    state = next;
    renderReceiver();
  }

  async function loadAirspace() {
    const request = ++airspaceRequest;
    let next = await api("/api/airspace?zones=0");
    if (request !== airspaceRequest) return;
    if (airspaceRevision !== next.tfrRevision) {
      next = await api("/api/airspace");
      if (request !== airspaceRequest) return;
      airspaceRevision = next.tfrRevision;
    } else {
      next.zones = airspace.zones;
    }
    airspace = next;
    renderAirspace();
  }

  const tabs = ["live", "log", "tiles"];
  function pickTab(tab, focus = false) {
    activeTab = tab;
    for (const entry of tabs) {
      const selected = entry === tab;
      const button = $(entry + "-tab");
      button.setAttribute("aria-selected", String(selected));
      button.tabIndex = selected ? 0 : -1;
      $(entry + "-panel").hidden = !selected;
      if (selected && focus) button.focus();
    }
    if (tab === "log") loadLog();
    if (tab === "tiles") {
      if (!$("tiles-lat").value && location()) setInputs("tiles", location());
      loadTiles();
    }
  }

  for (const entry of tabs) {
    $(entry + "-tab").addEventListener("click", () => pickTab(entry));
    $(entry + "-tab").addEventListener("keydown", (event) => {
      const index = tabs.indexOf(entry);
      const offsets = {ArrowRight: 1, ArrowLeft: -1};
      if (Object.hasOwn(offsets, event.key)) {
        event.preventDefault();
        pickTab(tabs[(index + offsets[event.key] + tabs.length) % tabs.length], true);
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault();
        pickTab(event.key === "Home" ? tabs[0] : tabs.at(-1), true);
      }
    });
  }

  function updateActionAvailability() {
    const receiver = state.receiver;
    const caps = receiver.capabilities || [];
    const ready = receiver.status === "receiving";
    const canLog = ready && caps.includes("log");
    const canTiles = ready && caps.includes("tiles");
    const uploading = ["planning", "downloading", "sending"].includes(tileState.phase);
    const stillPlanned = tilePlanInput && JSON.stringify(tilePlanInput) === JSON.stringify(tileInputs());
    if ($("log-read").getAttribute("aria-busy") !== "true") $("log-read").disabled = !canLog;
    if ($("log-clear").getAttribute("aria-busy") !== "true") $("log-clear").disabled = !canLog;
    $("disconnect-button").disabled = receiver.status === "disconnected" || $("disconnect-button").getAttribute("aria-busy") === "true";
    $("tiles-plan").disabled = !canTiles || uploading || $("tiles-plan").getAttribute("aria-busy") === "true";
    $("tiles-send").disabled = !canTiles || uploading || !tileState.storageKnown || tileState.phase !== "planned" || !stillPlanned || $("tiles-send").getAttribute("aria-busy") === "true";
    $("tile-availability").textContent = !ready ? "Verbind een ontvanger om kaarten te plannen." : !canTiles ? "Deze ontvanger ondersteunt geen kaartoverdracht." : "";
    const savingAtak = $("atak-save").getAttribute("aria-busy") === "true";
    $("atak-save").disabled = !atak || savingAtak;
    $("atak-fields").disabled = !atak || savingAtak;
  }

  function setInputs(prefix, values) {
    $(prefix + "-lat").value = values ? Math.round(values[0] * 1e7) / 1e7 : "";
    $(prefix + "-lon").value = values ? Math.round(values[1] * 1e7) / 1e7 : "";
  }

  function fromMap() {
    const center = map.getCenter().wrap();
    return [center.lat, center.lng];
  }

  function tileInputs() {
    return {lat: $("tiles-lat").valueAsNumber, lon: $("tiles-lon").valueAsNumber, radiusKm: $("tiles-radius").valueAsNumber};
  }

  async function refreshPorts() {
    const value = await api("/api/ports");
    const select = $("port-select");
    const selected = select.value || state.receiver.preferredPort || "auto";
    const all = [...new Set((value.ports || []).concat(selected === "auto" ? [] : [selected]))];
    const options = [new Option("Automatisch zoeken", "auto")];
    for (const port of all) options.push(new Option(port, port));
    select.replaceChildren(...options);
    select.value = selected;
    if (!all.length) message($("port-message"), "Geen COM-poorten gevonden.");
  }

  function syncAtakForm() {
    $("atak-enabled").checked = Boolean(atak?.enabled);
    $("atak-host").value = atak?.host || "";
    $("atak-host").required = Boolean(atak?.enabled);
    $("atak-port").value = atak?.port || 4242;
  }

  function renderAtak() {
    if (!atakDraftChanged) syncAtakForm();
    const states = {
      off: "ATAK-uitvoer uitgeschakeld.",
      waiting: "Wacht op een actuele dronepositie.",
      ready: "UDP-verzending actief. Ontvangst in ATAK is onbevestigd.",
      error: atak.error || "UDP-verzending mislukt.",
    };
    const status = $("atak-status");
    const summary = states[atak.state] || "ATAK-status onbekend.";
    if (status.textContent !== summary) status.textContent = summary;
    status.classList.toggle("error", atak.state === "error");

    const details = [];
    if (atak.enabled && atak.host) {
      const host = atak.host.includes(":") && !atak.host.startsWith("[") ? `[${atak.host}]` : atak.host;
      details.push(`Bestemming ${host}:${atak.port}`);
      if (atak.sent > 0) {
        const quantity = integer.format(atak.sent);
        details.push(atak.sent === 1 ? "1 UDP-pakket lokaal verzonden" : `${quantity} UDP-pakketten lokaal verzonden`);
        const lastSentAt = Date.parse(atak.lastSentAt);
        if (Number.isFinite(lastSentAt)) details.push(datetime.format(lastSentAt));
      }
    }
    message($("atak-send-detail"), details.join(" · "));
    updateActionAvailability();
  }

  async function loadAtak() {
    if ($("atak-save").getAttribute("aria-busy") === "true") return;
    const request = ++atakRequest;
    try {
      const next = await api("/api/atak");
      if (request !== atakRequest) return;
      atak = next;
      renderAtak();
    } catch {
      if (request !== atakRequest) return;
      message($("atak-status"), "ATAK-status kon niet worden opgehaald.", true);
    }
  }

  function showSettings(section) {
    setInputs("location", location());
    $("traffic-enabled").checked = Boolean(airspace.trafficEnabled);
    $("traffic-radius").value = airspace.radiusKm || 10;
    $("traffic-source").value = airspace.source || "";
    message($("location-message"));
    message($("airspace-message"));
    message($("atak-message"));
    atakDraftChanged = false;
    syncAtakForm();
    const value = state.receiver.preferredPort || "auto";
    const select = $("port-select");
    if (![...select.options].some((option) => option.value === value)) select.add(new Option(value, value));
    select.value = value;
    $("settings-dialog").showModal();
    if (section === "receiver") $("port-select").focus();
    if (section === "droneguide") $("droneguide-file").focus();
    action($("refresh-ports"), $("port-message"), refreshPorts);
    loadAtak();
  }

  function formatUTC(seconds) {
    if (!Number.isFinite(seconds) || seconds < 1704067200 || seconds > 4294967295) return "Klok niet ingesteld";
    return datetime.format(new Date(seconds * 1000));
  }

  function yes(value) {
    return value === true || value === 1;
  }

  function renderLog(data) {
    const entries = data.entries || [];
    $("log-count").textContent = integer.format(entries.length);
    const notes = [];
    if (data.missed) notes.push(`${integer.format(data.missed)} detecties waren al uit het ontvangergeheugen verdwenen.`);
    if (data.clearedSinceRead) notes.push("Het ontvangerlogboek is gewist. De onlangs gelezen detecties staan hieronder.");
    message($("log-message"), notes.join(" "));
    const rows = [];
    for (const entry of entries) {
      const row = make("article", "log-entry");
      const header = make("div", "contact-row");
      header.append(make("strong", "", entry.uas || entry.mac || "Onbekende drone"));
      if (yes(entry.active)) header.append(badge("ACTIEF", "teal"));
      row.append(header, make("p", "", formatUTC(entry.last || entry.first)));
      const facts = [
        Number.isFinite(entry.max_h) && "max. " + metric(entry.max_h, "m"),
        Number.isFinite(entry.peak_rssi) && metric(entry.peak_rssi, "dBm", integer),
        Number.isFinite(entry.dur) && metric(entry.dur, "s", integer),
        entry.mac && entry.uas && entry.mac,
      ].filter(Boolean);
      if (facts.length) row.append(make("p", "", facts.join(" · ")));
      const flags = make("div", "badges");
      if (yes(entry.emerg)) flags.append(badge("NOODSTATUS GEMELD", "danger"));
      if (entry.auth_state === "invalid") flags.append(badge("ONGELDIGE ID-HANDTEKENING", "danger"));
      if (entry.auth_state === "test_key") flags.append(badge("TESTSLEUTEL", "dim"));
      if (entry.tfr_id) flags.append(badge((yes(entry.in_tfr) ? "IN FAA-ZONE " : "FAA-ZONE ") + entry.tfr_id, "amber"));
      if (entry.class_type === 1 && Number.isFinite(entry.class_eu)) flags.append(badge("EU-KLASSE " + entry.class_eu, "dim"));
      if (flags.childElementCount) row.append(flags);
      rows.push(row);
    }
    if (!rows.length) rows.push(make("p", "notice", "Er zijn geen uitgelezen detecties."));
    $("log-list").replaceChildren(...rows);
  }

  async function loadLog() {
    try {
      renderLog(await api("/api/device/log"));
    } catch (error) {
      message($("log-message"), error.message, true);
    }
  }

  function megabytes(bytes) {
    return metric(bytes / 1048576, "MiB");
  }

  function renderTiles() {
    const output = $("tiles-output");
    const plan = tileState.plan;
    const nodes = [];
    if (plan) {
      nodes.push(metricGrid([
        ["Kaartstraal", metric(plan.radiusKm, "km")],
        ["Kaarttegels", integer.format(plan.tileCount ?? 0)],
        ["Nog te verzenden", integer.format(plan.missing ?? 0)],
        ["Benodigd / beschikbaar", `${megabytes(plan.planBytes)} / ${tileState.storageKnown ? megabytes(plan.capacityBytes) : "onbekend"}`],
      ]));
      if (!tileState.storageKnown) nodes.push(make("p", "notice", "Overdracht vereist dat de ontvanger de beschikbare opslag rapporteert."));
      if (plan.shrunk && Array.isArray(plan.radiiKm)) {
        const zooms = plan.radiiKm.map((radius, index) => radius >= 0 ? `z${12 + index} · ${metric(radius, "km")}` : "").filter(Boolean);
        nodes.push(make("p", "notice", "Aangepast aan opslagruimte · " + zooms.join(" · ")));
      }
    }
    const phases = {
      planning: "Opslag en tegels opvragen…", planned: "Kaartplan gereed", downloading: "Kaarttegels downloaden…",
      sending: "Kaarttegels naar ontvanger sturen…", done: "Kaartoverdracht voltooid", failed: "Kaartoverdracht mislukt",
    };
    if (phases[tileState.phase]) {
      nodes.push(make("p", `notice ${tileState.phase === "failed" ? "error" : ""}`, [phases[tileState.phase], tileState.error].filter(Boolean).join(" · ")));
    }
    if (tileState.phase === "done" && tileState.remaining) {
      const count = integer.format(tileState.remaining);
      const summary = count === "1" ? "1 kaarttegel is nog" : `${count} kaarttegels zijn nog`;
      nodes.push(make("p", "notice", summary + " niet op de ontvanger beschikbaar."));
    }
    if (["downloading", "sending"].includes(tileState.phase)) {
      const progress = make("progress");
      progress.max = Math.max(tileState.total || 0, 1);
      progress.value = tileState.completed || 0;
      progress.setAttribute("aria-label", "Voortgang kaartoverdracht");
      nodes.push(progress, make("p", "notice", `${integer.format(tileState.completed || 0)} / ${integer.format(tileState.total || 0)} tegels`));
    }
    output.replaceChildren(...nodes);
    updateActionAvailability();
  }

  async function loadTiles() {
    if (tilesUpdating) return;
    tilesUpdating = true;
    try {
      tileState = await api("/api/device/tiles/status");
      message($("tiles-message"));
      renderTiles();
    } catch (error) {
      message($("tiles-message"), error.message, true);
    } finally {
      tilesUpdating = false;
    }
  }

  function trafficInput(enabled = $("traffic-enabled").checked) {
    return {enabled, radiusKm: $("traffic-radius").valueAsNumber || 10, source: $("traffic-source").value.trim()};
  }

  $("settings-button").addEventListener("click", () => showSettings());
  $("receiver-control").addEventListener("click", () => showSettings("receiver"));
  $("empty-connect").addEventListener("click", () => showSettings("receiver"));
  $("settings-close").addEventListener("click", () => $("settings-dialog").close());
  $("license-close").addEventListener("click", () => $("license-dialog").close());
  $("license-open").addEventListener("click", async () => {
    const license = $("license-text");
    license.textContent = "Licentie laden…";
    $("license-dialog").showModal();
    try {
      const response = await fetch("/LICENSE");
      if (!response.ok) throw new Error();
      license.textContent = await response.text();
    } catch {
      license.textContent = "De licentie kon niet worden geladen.";
    }
  });
  $("clear-close").addEventListener("click", () => $("clear-dialog").close());
  $("refresh-ports").addEventListener("click", () => action($("refresh-ports"), $("port-message"), refreshPorts));
  $("receiver-form").addEventListener("submit", (event) => {
    event.preventDefault();
    action($("connect-button"), $("port-message"), async () => {
      await api("/api/connect", {port: $("port-select").value});
      await loadReceiver();
    });
  });
  $("disconnect-button").addEventListener("click", () => action($("disconnect-button"), $("port-message"), async () => {
    await api("/api/disconnect", {});
    await loadReceiver();
  }));
  $("atak-form").addEventListener("input", () => {
    atakDraftChanged = true;
    $("atak-host").required = $("atak-enabled").checked;
    message($("atak-message"));
  });
  $("atak-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const values = {
      enabled: $("atak-enabled").checked,
      host: $("atak-host").value.trim(),
      port: $("atak-port").valueAsNumber,
    };
    action($("atak-save"), $("atak-message"), async () => {
      ++atakRequest;
      $("atak-fields").disabled = true;
      atak = await api("/api/atak", values);
      atakDraftChanged = false;
      renderAtak();
      message($("atak-message"), "ATAK-instellingen opgeslagen.");
    });
  });
  $("demo-button").addEventListener("click", () => action($("demo-button"), $("app-error"), async () => {
    const enabled = !state.receiver.demo;
    await api("/api/demo", {enabled});
    if (enabled) positioned = false;
    await loadReceiver();
    await loadAirspace();
  }));
  $("fit-button").addEventListener("click", fitAll);
  $("home-button").addEventListener("click", () => {
    const home = location();
    if (home) fitPositions([home], 14);
  });
  $("traffic-toggle").addEventListener("click", () => action($("traffic-toggle"), $("app-error"), async () => {
    await api("/api/airspace/traffic", {enabled: !airspace.trafficEnabled, radiusKm: airspace.radiusKm || 10, source: airspace.source || ""});
    await loadAirspace();
  }));
  $("location-map").addEventListener("click", () => setInputs("location", fromMap()));
  $("location-form").addEventListener("submit", (event) => {
    event.preventDefault();
    action(event.submitter, $("location-message"), async () => {
      const lat = $("location-lat").valueAsNumber;
      const lon = $("location-lon").valueAsNumber;
      await api("/api/location", {lat, lon});
      await loadReceiver();
      message($("location-message"), "Ontvangerlocatie opgeslagen.");
    });
  });
  $("location-clear").addEventListener("click", () => action($("location-clear"), $("location-message"), async () => {
    await api("/api/location", {lat: null, lon: null});
    setInputs("location", null);
    await loadReceiver();
    message($("location-message"), "Ontvangerlocatie verwijderd.");
  }));
  $("airspace-form").addEventListener("submit", (event) => {
    event.preventDefault();
    action(event.submitter, $("airspace-message"), async () => {
      await api("/api/airspace/traffic", trafficInput());
      await loadAirspace();
      message($("airspace-message"), "Verkeersinstellingen opgeslagen.");
    });
  });
  $("tfr-refresh").addEventListener("click", () => action($("tfr-refresh"), $("airspace-message"), async () => {
    await api("/api/airspace/refresh", {});
    await loadAirspace();
  }));
  $("droneguide-live").addEventListener("click", () => action($("droneguide-live"), $("droneguide-message"), async () => {
    await api("/api/droneguide/live", {enabled: !droneguide.liveEnabled});
    await loadDroneguide();
  }));
  $("droneguide-active-only").addEventListener("click", () => action($("droneguide-active-only"), $("droneguide-message"), async () => {
    await api("/api/droneguide/filter", {activeOnly: !droneguide.activeOnly});
    await loadDroneguide();
  }));
  $("droneguide-refresh").addEventListener("click", () => action($("droneguide-refresh"), $("droneguide-message"), async () => {
    await api("/api/droneguide/refresh", {});
    await loadDroneguide();
  }).then(renderDroneguideStatus));
  $("droneguide-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const file = $("droneguide-file").files[0];
    if (!file) return;
    action($("droneguide-import"), $("droneguide-message"), async () => {
      await api("/api/droneguide/import", file);
      droneguideVisible = true;
      await loadDroneguide();
      $("droneguide-form").reset();
      message($("droneguide-message"), "Bestand ingelezen. De app gebruikt nu de geïmporteerde gegevens.");
    });
  });
  $("droneguide-toggle").addEventListener("click", () => {
    if (!(droneguide.zones || []).length) {
      showSettings("droneguide");
      return;
    }
    droneguideVisible = !droneguideVisible;
    renderDroneguideStatus();
  });
  $("droneguide-fit").addEventListener("click", () => {
    droneguideVisible = true;
    renderDroneguideStatus();
    $("settings-dialog").close();
    const bounds = droneguideLayer.getBounds();
    if (bounds.isValid()) map.fitBounds(bounds, {padding: [55, 55], maxZoom: 15});
  });
  $("log-read").addEventListener("click", () => action($("log-read"), $("log-message"), async () => {
    renderLog(await api("/api/device/log/read", {}));
  }));
  $("log-clear").addEventListener("click", () => {
    message($("clear-message"));
    $("clear-dialog").showModal();
  });
  $("clear-confirm").addEventListener("click", () => action($("clear-confirm"), $("clear-message"), async () => {
    renderLog(await api("/api/device/log/clear", {}));
    $("clear-dialog").close();
  }));
  $("tiles-use-map").addEventListener("click", () => {
    const [lat, lon] = fromMap();
    if (Math.abs(lat) <= 85) setInputs("tiles", [lat, lon]);
    updateActionAvailability();
  });
  $("tiles-form").addEventListener("input", updateActionAvailability);
  $("tiles-form").addEventListener("submit", (event) => {
    event.preventDefault();
    action($("tiles-plan"), $("tiles-message"), async () => {
      const values = tileInputs();
      tilePlanInput = null;
      tileState = {phase: "planning"};
      renderTiles();
      try {
        tileState = await api("/api/device/tiles/plan", values);
        if (tileState.phase === "planned") tilePlanInput = values;
      } catch (error) {
        tileState = {phase: "failed", error: error.message};
      }
      renderTiles();
    });
  });
  $("tiles-send").addEventListener("click", () => action($("tiles-send"), $("tiles-message"), async () => {
    if (!tilePlanInput || !($("tiles-form").reportValidity())) return;
    try {
      tileState = await api("/api/device/tiles/send", tilePlanInput);
    } catch (error) {
      tileState = {phase: "failed", error: error.message, plan: tileState.plan};
    }
    renderTiles();
  }));
  map.on("moveend zoomend", renderMap);
  new ResizeObserver(() => map.invalidateSize({pan: false})).observe($("map"));

  async function refresh() {
    const results = await Promise.allSettled([loadReceiver(), loadAirspace(), loadDroneguide()]);
    if (results[0].status === "rejected") message($("app-error"), "Verbinding met de desktopapp onderbroken.", true);
    else if ($("app-error").textContent === "Verbinding met de desktopapp onderbroken.") message($("app-error"));
    if (results[1].status === "rejected") $("traffic-status").textContent = "Verkeersgegevens niet beschikbaar";
    if (results[2].status === "rejected") $("droneguide-status").textContent = "Droneguide-gegevens konden niet worden geladen.";
    if ($("settings-dialog").open) loadAtak();
    if (activeTab === "tiles" && $("tiles-plan").getAttribute("aria-busy") !== "true") loadTiles();
    window.setTimeout(refresh, 1000);
  }

  refresh();
})();
