// Blabbit landing page: the hero dictation loop and the score bars.
// Progressive enhancement: without JS the page reads the same, minus motion.
(() => {
  document.documentElement.classList.add("js");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Score bars fill when the table scrolls into view.
  const bars = document.querySelectorAll(".bar");
  const fill = (bar) => bar.style.setProperty("--v", bar.textContent.trim());
  if (reduced || !("IntersectionObserver" in window)) {
    bars.forEach(fill);
  } else {
    const seen = new IntersectionObserver((entries) => {
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        e.target.querySelectorAll(".bar").forEach(fill);
        seen.unobserve(e.target);
      });
    }, { threshold: 0.25 });
    const table = document.querySelector(".models");
    if (table) seen.observe(table);
  }

  // Hero: hold ⌥Space, speak, release, the words land.
  const typed = document.getElementById("typed");
  const pill = document.getElementById("pill");
  const time = document.getElementById("pill-time");
  const keys = [document.getElementById("key-mod"), document.getElementById("key-space")];
  if (!typed || !pill || reduced) return;

  const base = "Shipped the new settings window. Next up, ";
  const lines = [
    "the website and the first release on GitHub.",
    "fix the AirPods switch, then write the release notes.",
    "send the TypeScript notes to the Maynooth team.",
  ];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let n = 0;

  async function cycle() {
    const line = lines[n++ % lines.length];
    typed.textContent = base;
    await sleep(900);
    keys.forEach((k) => k && k.classList.add("down"));
    pill.classList.add("on");
    const seconds = 2 + Math.round(line.length / 18);
    for (let s = 0; s <= seconds; s++) {
      time.textContent = `0:${String(s).padStart(2, "0")}`;
      await sleep(s === seconds ? 200 : 520);
    }
    keys.forEach((k) => k && k.classList.remove("down"));
    pill.classList.remove("on");
    await sleep(160);
    // Blabbit inserts at once; the words appear in quick succession for the eye.
    const words = line.split(" ");
    for (let i = 0; i < words.length; i++) {
      typed.textContent = base + words.slice(0, i + 1).join(" ");
      await sleep(38);
    }
    await sleep(2600);
    cycle();
  }
  cycle();
})();
