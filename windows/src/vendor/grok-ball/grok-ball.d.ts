export interface GrokBallEngine {
  readonly emotionId: string;
  setEmotion(id: string): boolean;
  setGaze(x: number, y: number): void;
  setActive(active: boolean): void;
  renderStatic(): void;
  destroy(): void;
}
export interface GrokBallAPI {
  create(target: HTMLElement, options: { emotion: string; autostart: boolean; lite: boolean }): GrokBallEngine;
}
export const GrokBall: GrokBallAPI;
declare global {
  interface Window { GrokBall: GrokBallAPI }
}
export {};
