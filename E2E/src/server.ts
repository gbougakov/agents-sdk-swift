// Minimal self-contained Agents worker for the Swift client smoke test.
// Exposes a StateAgent (state sync + RPC) and a CallableAgent (pure RPC).
// No external API keys or bindings required.
import { Agent, callable, routeAgentRequest } from "agents";

interface Env {
  StateAgent: DurableObjectNamespace;
  CallableAgent: DurableObjectNamespace;
}

export interface StateAgentState {
  counter: number;
  items: string[];
  lastUpdated: string | null;
}

export class StateAgent extends Agent<Env, StateAgentState> {
  initialState: StateAgentState = {
    counter: 0,
    items: [],
    lastUpdated: null
  };

  @callable()
  increment(): StateAgentState {
    const next = {
      ...this.state,
      counter: this.state.counter + 1,
      lastUpdated: new Date().toISOString()
    };
    this.setState(next);
    return next;
  }

  @callable()
  setCounter(value: number): StateAgentState {
    const next = { ...this.state, counter: value, lastUpdated: new Date().toISOString() };
    this.setState(next);
    return next;
  }

  @callable()
  addItem(item: string): StateAgentState {
    const next = {
      ...this.state,
      items: [...this.state.items, item],
      lastUpdated: new Date().toISOString()
    };
    this.setState(next);
    return next;
  }

  @callable()
  resetState(): StateAgentState {
    this.setState(this.initialState);
    return this.initialState;
  }
}

export class CallableAgent extends Agent<Env, Record<string, never>> {
  @callable()
  add(a: number, b: number): number {
    return a + b;
  }

  @callable()
  echo(message: string): string {
    return message;
  }

  @callable()
  getTimestamp(): string {
    return new Date().toISOString();
  }

  @callable()
  async slowOperation(delayMs: number): Promise<string> {
    await new Promise((r) => setTimeout(r, delayMs));
    return `done after ${delayMs}ms`;
  }

  @callable()
  throwError(message: string): never {
    throw new Error(message);
  }
}

// Local `wrangler dev`/workerd does not populate `ctx.id.name` for
// idFromName()-addressed Durable Objects, so PartyServer's `.name` guard
// throws during session setup. routeAgentRequest's onBeforeConnect/onBeforeRequest
// hooks receive the resolved `lobby.name`; we stamp it onto the recognized
// `x-partykit-room` header so PartyServer can bootstrap the name. This is a
// local-dev shim only and does not affect the client protocol.
function withRoomName(req: Request, lobby: { name: string }): Request {
  const r = new Request(req);
  r.headers.set("x-partykit-room", lobby.name);
  return r;
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return (
      (await routeAgentRequest(request, env, {
        onBeforeConnect: (req, lobby) => withRoomName(req, lobby),
        onBeforeRequest: (req, lobby) => withRoomName(req, lobby)
      })) || new Response("not found", { status: 404 })
    );
  }
} satisfies ExportedHandler<Env>;
