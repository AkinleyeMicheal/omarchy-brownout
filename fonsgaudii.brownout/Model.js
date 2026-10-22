// Pure parsing/formatting helpers for the brownout bar widget.
// Defensive: state.json may not exist yet, and `brownout top` output may be
// empty or malformed — everything degrades to friendly defaults.

function parseState(raw) {
  var defaults = {
    mode: "auto",
    engaged: false,
    reason: "",
    engaged_at: 0,
    battery_pct: -1,
    on_battery: 0,
    engage_threshold: 20,
    release_threshold: 25,
    profile: {},
    paused_config: []
  };
  try {
    var data = JSON.parse(String(raw || ""));
    if (!data || typeof data !== "object") return defaults;
    for (var k in defaults) if (data[k] !== undefined && data[k] !== null) defaults[k] = data[k];
  } catch (e) {}
  if (defaults.mode !== "on" && defaults.mode !== "off") defaults.mode = "auto";
  defaults.engaged = defaults.engaged === true || defaults.engaged === "true";
  defaults.on_battery = defaults.on_battery === 1 || defaults.on_battery === true ? 1 : 0;
  if (!(defaults.paused_config instanceof Array)) defaults.paused_config = [];
  return defaults;
}

function parseTop(raw) {
  try {
    var data = JSON.parse(String(raw || ""));
    if (!data || !(data.units instanceof Array)) return [];
    return data.units.filter(function (r) { return r && typeof r.id === "string"; });
  } catch (e) {
    return [];
  }
}

function modeLabel(mode) {
  if (mode === "on") return "On";
  if (mode === "off") return "Off";
  return "Auto";
}

function statusText(st) {
  if (!st) return "…";
  if (st.engaged) {
    if (st.reason) return "Active — " + st.reason;
    return "Active";
  }
  if (st.mode === "off") return "Suppressed until auto";
  return "Inactive";
}

function powerText(st) {
  if (!st) return "";
  var pct = typeof st.battery_pct === "number" && st.battery_pct >= 0 ? st.battery_pct + "%" : "?%";
  return pct + (st.on_battery === 1 ? " · on battery" : " · plugged in");
}

function fmtDuration(seconds) {
  if (!seconds || seconds < 1) return "0s";
  if (seconds < 60) return Math.floor(seconds) + "s";
  if (seconds < 3600) return Math.floor(seconds / 60) + "m " + Math.floor(seconds % 60) + "s";
  return Math.floor(seconds / 3600) + "h " + Math.floor((seconds % 3600) / 60) + "m";
}

function fmtMetrics(row) {
  var parts = [];
  parts.push("24h " + (row.cpu_pct_24h !== undefined ? row.cpu_pct_24h.toFixed(1) : "0") + "%");
  if (row.batt_cpu_min_7d) parts.push("batt " + row.batt_cpu_min_7d + "m/7d");
  if (row.mem_mb) parts.push(row.mem_mb >= 1024 ? (row.mem_mb / 1024).toFixed(1) + "GB" : Math.round(row.mem_mb) + "MB");
  if (row.live_cpu_pct !== null && row.live_cpu_pct !== undefined) parts.push("live " + row.live_cpu_pct.toFixed(1) + "%");
  return parts.join("  ·  ");
}

function profileSummary(st) {
  if (!st || !st.engaged) return "Blur, animations, brightness, power profile and pause list are untouched while inactive.";
  var bits = [];
  if (st.profile) {
    if (st.profile.brightness_pct !== undefined) bits.push("dimmed");
    if (st.profile.blur !== undefined || st.profile.animations !== undefined ||
        st.profile.shadow !== undefined || st.profile.opacity_active !== undefined) {
      bits.push("fx reduced");
    }
    if (st.profile.ppd !== undefined) bits.push("power-saver");
    if (st.profile.kbd) bits.push("kbd off");
    if (st.profile.wifi) bits.push("wifi ps");
    if (st.profile.monitor) bits.push("refresh capped");
  }
  var paused = st.profile && st.profile.paused instanceof Array ? st.profile.paused : [];
  var text = bits.length ? bits.join(" · ") : "profile active";
  if (paused.length) text += " — paused: " + paused.map(function (u) { return u.replace(/\.service$/, ""); }).join(", ");
  return text;
}
