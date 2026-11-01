import { GrokBall } from "../vendor/grok-ball/grok-ball.js";
import type { GrokBallEngine } from "../vendor/grok-ball/grok-ball.js";

/** Keeps the upstream SVG engine alive while the surrounding panel is rendered again. */
export class GrokBallView {
  readonly element = document.createElement("span");
  private engine: GrokBallEngine | null = null;
  private readonly motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  private previousRect: DOMRect | null = null;
  private relocation: Animation | null = null;

  constructor() {
    this.element.className = "cc-grok-ball";
    this.motion.addEventListener("change", () => this.updateMotion());
    document.addEventListener("visibilitychange", () => this.updateMotion());
    window.addEventListener("pagehide", () => this.engine?.destroy(), { once: true });
  }

  prepareMove(): void {
    this.previousRect = this.element.isConnected ? this.element.getBoundingClientRect() : null;
  }

  mount(slot: HTMLElement, emotion: string): void {
    slot.appendChild(this.element);
    if (!this.engine) {
      this.engine = GrokBall.create(this.element, {
        emotion, autostart: !this.motion.matches && !document.hidden, lite: false,
      });
    }
    this.setEmotion(emotion);
    this.updateMotion();
    const previous = this.previousRect;
    const next = this.element.getBoundingClientRect();
    if (!this.motion.matches && previous && previous.width > 0 && next.width > 0 &&
        (Math.abs(previous.x - next.x) > 1 || Math.abs(previous.y - next.y) > 1)) {
      this.relocation?.cancel();
      this.relocation = this.element.animate([
        { transformOrigin: "top left", transform: `translate(${previous.x - next.x}px, ${previous.y - next.y}px) scale(${previous.width / next.width})` },
        { transformOrigin: "top left", transform: "none" },
      ], { duration: 250, easing: "cubic-bezier(0.22, 1, 0.36, 1)" });
    }
    this.previousRect = null;
  }

  setEmotion(emotion: string): void {
    this.element.dataset.emotion = emotion;
    if (this.engine?.emotionId !== emotion) this.engine?.setEmotion(emotion);
  }

  setGaze(x: number, y: number): void {
    if (!this.motion.matches) this.engine?.setGaze(x, y);
  }

  private updateMotion(): void {
    const active = !this.motion.matches && !document.hidden;
    this.element.dataset.reducedMotion = String(this.motion.matches);
    this.engine?.setActive(active);
    if (!active) this.engine?.renderStatic();
  }
}
