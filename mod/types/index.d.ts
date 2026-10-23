// The glaude mod's $.state contract.

/** A tool call held for an answer in Glaude, shown in the terminal's band too. */
export type HeldAsk = {
  id: string
  tool: string
  /** What the call does, as the band shows it (the command, the file). */
  detail: string
}

declare module 'claude-code' {
  interface PluginState {
    glaude: {
      /** Calls waiting on Allow or Deny, oldest first; the band answers the first. */
      held: HeldAsk[]
    }
  }
}
