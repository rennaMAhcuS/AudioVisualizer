import { run } from "uebersicht";

// Config
const SCALE = 1.0; // overall size multiplier; current values are SCALE = 1

// Base geometry (at SCALE = 1)
// NUM_BARS must match --bands passed to the Swift binary
const NUM_BARS = 119;
const BASE_BAR_W = 4; // px per bar
const BASE_BAR_GAP = 3; // px gap between bars
const BASE_PEAK_H = 3; // peak dot height in px
// Bar height as % of viewport height so it scales across displays.
// Tune this if bars look too tall/short on your screen.
const BASE_MAX_H_VH = 19.75;

// Colors
const BAR_COLOR = "rgba(255,255,255,0.92)"; // fast bars (Rainmeter Color2)
const PEAK_COLOR = "rgb(236,196,46)"; // slow peak dot (Rainmeter Color1)

// Glow
// Increase spread or opacity for a stronger halo; "none" to disable.
const BAR_GLOW = "0 0 5px 1px rgba(255,255,255,0.3)";
const PEAK_GLOW = "0 0 6px 2px rgba(236,196,46,0.8)";

// Transitions
// These bridge the ~23ms FFT hop so motion looks continuous at 60fps.
// Raise BAR_TRANSITION to "80ms" for smoother feel; "16ms" for snappier.
// DOT_TRANSITION should stay ~2x bar.
const BAR_TRANSITION = "height 60ms ease-out";
const DOT_TRANSITION = "bottom 100ms ease-out";

// Widget position
const BOTTOM_OFFSET = "16%";

// Derived (scale applied; MAX_H computed live from viewport)
const BAR_W = Math.max(1, Math.round(BASE_BAR_W * SCALE));
const BAR_GAP = Math.max(1, Math.round(BASE_BAR_GAP * SCALE));
const PEAK_H = Math.max(1, Math.round(BASE_PEAK_H * SCALE));
const WIDGET_W = NUM_BARS * (BAR_W + BAR_GAP);

// Recomputed each render so MAX_H tracks live viewport size
const getMaxH = () =>
  Math.round(window.innerHeight * (BASE_MAX_H_VH / 100) * SCALE);

export const refreshFrequency = 16; // ~60fps

export const className = `
  bottom: ${BOTTOM_OFFSET};
  left: 50%;
  transform: translateX(-50%);
  width: ${WIDGET_W}px;
`;

export const command =
  'cat /tmp/ubersicht-visualizer.json 2>/dev/null || echo \'{"f":[],"s":[]}\'';

export const initialState = {
  fast: Array(NUM_BARS).fill(0),
  slow: Array(NUM_BARS).fill(0),
};

export const updateState = (event, previousState) => {
  if (event.type !== "UB/COMMAND_RAN") return previousState;
  try {
    const parsed = JSON.parse(event.output);
    const f = parsed.f,
      s = parsed.s;
    if (!Array.isArray(f) || f.length !== NUM_BARS) return previousState;
    return { fast: f, slow: s };
  } catch {
    return previousState;
  }
};

export const render = ({ fast, slow }) => {
  const MAX_H = getMaxH();
  const f = fast && fast.length === NUM_BARS ? fast : Array(NUM_BARS).fill(0);
  const s = slow && slow.length === NUM_BARS ? slow : Array(NUM_BARS).fill(0);

  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-end",
        gap: `${BAR_GAP}px`,
        height: `${MAX_H + PEAK_H + 2}px`,
      }}
    >
      {f.map((v, i) => {
        const barH = Math.max(1, Math.round(v * MAX_H));
        const dotBot = Math.max(0, Math.round(s[i] * MAX_H) - PEAK_H);

        return (
          <div
            key={i}
            style={{
              width: `${BAR_W}px`,
              height: "100%",
              position: "relative",
            }}
          >
            <div
              style={{
                position: "absolute",
                bottom: 0,
                width: "100%",
                height: `${barH}px`,
                backgroundColor: BAR_COLOR,
                borderRadius: "1px 1px 0 0",
                boxShadow: BAR_GLOW,
                transition: BAR_TRANSITION,
              }}
            />
            <div
              style={{
                position: "absolute",
                bottom: `${dotBot}px`,
                width: "100%",
                height: `${PEAK_H}px`,
                backgroundColor: PEAK_COLOR,
                borderRadius: "0",
                boxShadow: PEAK_GLOW,
                transition: DOT_TRANSITION,
              }}
            />
          </div>
        );
      })}
    </div>
  );
};
