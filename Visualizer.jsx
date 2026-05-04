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
const BAR_COLOR = "rgba(255,255,255,0.92)";
const PEAK_COLOR = "rgb(236,196,46)";

// Glow via CSS filter (GPU-composited layer effect, unlike canvas shadowBlur which is software-rendered)
const CANVAS_FILTER = "drop-shadow(0 0 4px rgba(255,255,255,0.55)) drop-shadow(0 0 3px rgba(236,196,46,0.5))";

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

const WS_PORT = 9001;

export const className = `
  bottom: ${BOTTOM_OFFSET};
  left: 50%;
  transform: translateX(-50%);
  width: ${WIDGET_W}px;
`;

export const init = (dispatch) => {
  let ws = null;
  let paused = false;

  const connect = () => {
    if (paused) return;
    if (ws) { ws.onclose = null; ws.onerror = null; ws.close(); ws = null; }
    ws = new WebSocket(`ws://127.0.0.1:${WS_PORT}`);
    ws.binaryType = "arraybuffer";
    let hbInterval = null;
    // Heartbeat: Swift stops pushing if it doesn't hear from us for >2s.
    // This covers the case where the WebSocket stays open but the renderer is paused.
    ws.onopen = () => {
      ws.send("");
      hbInterval = setInterval(() => ws.readyState === WebSocket.OPEN && ws.send(""), 1000);
    };
    ws.onmessage = (e) => {
      if (!(e.data instanceof ArrayBuffer)) return;
      const arr = new Float32Array(e.data);
      if (arr.length !== NUM_BARS * 2) return;
      dispatch({ type: "FFT", fast: arr.subarray(0, NUM_BARS), slow: arr.subarray(NUM_BARS) });
    };
    ws.onclose = () => { clearInterval(hbInterval); ws = null; if (!paused) setTimeout(connect, 2000); };
    ws.onerror = () => ws && ws.close();
  };

  // Stop processing entirely when the desktop is covered (fullscreen app / screen lock).
  document.addEventListener("visibilitychange", () => {
    paused = document.hidden;
    if (paused) { ws && ws.close(); }
    else connect();
  });

  connect();
};

export const initialState = {
  fast: new Float32Array(NUM_BARS),
  slow: new Float32Array(NUM_BARS),
};

export const updateState = (event, previousState) => {
  if (event.type !== "FFT") return previousState;
  return { fast: event.fast, slow: event.slow };
};

const draw = (canvas, fast, slow) => {
  const MAX_H = getMaxH();
  const H = MAX_H + PEAK_H + 2;
  if (canvas.width !== WIDGET_W) canvas.width = WIDGET_W;
  if (canvas.height !== H) canvas.height = H;

  const ctx = canvas.getContext("2d");
  ctx.clearRect(0, 0, WIDGET_W, H);

  ctx.fillStyle = BAR_COLOR;
  for (let i = 0; i < NUM_BARS; i++) {
    const barH = Math.max(1, Math.round(fast[i] * MAX_H));
    ctx.fillRect(i * (BAR_W + BAR_GAP), H - barH, BAR_W, barH);
  }

  ctx.fillStyle = PEAK_COLOR;
  for (let i = 0; i < NUM_BARS; i++) {
    const dotBot = Math.max(0, Math.round(slow[i] * MAX_H) - PEAK_H);
    ctx.fillRect(i * (BAR_W + BAR_GAP), H - dotBot - PEAK_H, BAR_W, PEAK_H);
  }
};

export const render = ({ fast, slow }) => {
  const MAX_H = getMaxH();
  const H = MAX_H + PEAK_H + 2;
  const f = fast && fast.length === NUM_BARS ? fast : new Float32Array(NUM_BARS);
  const s = slow && slow.length === NUM_BARS ? slow : new Float32Array(NUM_BARS);

  return (
    <canvas
      ref={(canvas) => canvas && draw(canvas, f, s)}
      width={WIDGET_W}
      height={H}
      style={{ filter: CANVAS_FILTER }}
    />
  );
};
