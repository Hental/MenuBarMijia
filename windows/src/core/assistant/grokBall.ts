

// MARK: - GrokBall Emotion & Radial Stage Contract (#114)

export type GrokBallRadialSlot = "topLeft" | "topRight" | "bottomLeft" | "bottomRight";

export const GROK_BALL_RADIAL_SLOTS: readonly GrokBallRadialSlot[] = [
  "topLeft",
  "topRight",
  "bottomLeft",
  "bottomRight",
];

export type GrokBallAssistantPhase = "idle" | "thinking" | "done" | "failed" | "awaitingChoice";

export interface GrokBallEmotionContext {
  readonly timeBucket: string;
  readonly activeDeviceCount: number;
  readonly speechListening: boolean;
  readonly assistantState: GrokBallAssistantPhase;
  readonly isRecommending?: boolean;
  readonly hasErrorToast?: boolean;
  readonly isPointerTracking?: boolean;
  readonly isStageExpanded?: boolean;
  readonly hasRecentCelebration?: boolean;
}

/**
 * Pure, deterministic state mapper from home & assistant lifecycle to `TyCoding/grok-ball` `emotionId`.
 * Shared with `Sources/MijiaCore/GrokBallEmotionResolver.swift` and pinned by `Tests/Fixtures/grok_ball_golden.json` (#114).
 */
export function resolveGrokBallEmotion(ctx: GrokBallEmotionContext): string {
  if (ctx.speechListening) return "35";
  if (ctx.assistantState === "thinking" || ctx.isRecommending === true) return "30";
  if (ctx.hasErrorToast === true || ctx.assistantState === "failed") return "34";
  if (ctx.hasRecentCelebration === true || ctx.assistantState === "done") return "33";
  if (ctx.assistantState === "awaitingChoice" || ctx.isStageExpanded === true || ctx.isPointerTracking === true) {
    return "03";
  }
  if (ctx.timeBucket === "深夜" && ctx.activeDeviceCount === 0) return "00";
  return "02";
}
