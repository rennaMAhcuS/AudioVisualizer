import { run } from "uebersicht";

// Config
const SCALE = 1.0; // overall size multiplier (1.0 = original)
const FONT_SIZE = `${1.3 * SCALE}vh`;
const LABEL_COLOR = "rgba(255,255,255,0.45)";
const VALUE_COLOR = "rgba(255,255,255,0.9)";
const BOTTOM = "12.5%"; // distance from screen bottom; sits below Visualizer

export const refreshFrequency = 100;

export const className = `
  bottom: ${BOTTOM};
  left: 50%;
  transform: translateX(-50%);
  font-family: Futura, sans-serif;
  text-align: center;
  white-space: nowrap;
`;

export const command = async (dispatch) => {
  const result = (
    await run(
      `osascript -e 'if application "Music" is running then tell application "Music" to if player state is playing then return (name of current track) & "|" & (artist of current track)'`,
    )
  ).trim();

  const parts = result ? result.split("|") : [];
  const track = parts[0] || "";
  const artist = parts[1] || "";
  dispatch({ type: "SET_INFO", track, artist });
};

export const initialState = { track: "", artist: "" };

export const updateState = (event, previousState) => {
  if (event.type !== "SET_INFO") return previousState;
  return { track: event.track, artist: event.artist };
};

const Label = ({ children, style }) => (
  <span
    style={{
      color: LABEL_COLOR,
      fontSize: FONT_SIZE,
      letterSpacing: "0.1em",
      ...style,
    }}
  >
    {children}
  </span>
);

const Value = ({ children }) => (
  <span style={{ color: VALUE_COLOR, fontSize: FONT_SIZE }}>{children}</span>
);

export const render = ({ track, artist }) => {
  if (!track)
    return (
      <div style={{ display: "flex", justifyContent: "center" }}>
        <Label>NO MUSIC PLAYING</Label>
      </div>
    );
  return (
    <div
      style={{
        display: "flex",
        gap: "0.25em",
        justifyContent: "center",
        alignItems: "baseline",
      }}
    >
      <Label>NOW PLAYING:</Label>
      <Value>{track}</Value>
      {artist && <Label style={{ marginLeft: "0.75em" }}>ARTIST:</Label>}
      {artist && <Value>{artist}</Value>}
    </div>
  );
};
