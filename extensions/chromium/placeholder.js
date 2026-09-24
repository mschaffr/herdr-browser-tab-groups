const COLORS = { grey: "#9aa0a6", blue: "#8ab4f8", red: "#f28b82", yellow: "#fdd663", green: "#81c995",
                 pink: "#ff8bcb", purple: "#c58af9", cyan: "#78d9ec", orange: "#fcad70" };
const q = new URLSearchParams(location.search);
const title = q.get("title") || "workspace";
document.title = `${title} · no app yet`;
document.getElementById("title").textContent = title;
document.getElementById("swatch").style.background = COLORS[q.get("color")] || COLORS.grey;
