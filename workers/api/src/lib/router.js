/**
 * A tiny path router.
 *
 * Deliberately hand-rolled rather than `URLPattern`: that API is behind a
 * compat flag on some Workers runtime versions, and a 40-line segment matcher
 * has no such dependency. Routes are matched in registration order, so put
 * literals before params if they ever collide.
 */

const split = (path) => path.replace(/^\/+|\/+$/g, '').split('/').filter(Boolean);

export function compile(pattern) {
  return split(pattern).map((seg) =>
    seg.startsWith(':') ? { param: seg.slice(1) } : { literal: seg },
  );
}

export function matchSegments(compiled, segments) {
  if (compiled.length !== segments.length) return null;
  const params = {};
  for (let i = 0; i < compiled.length; i++) {
    const part = compiled[i];
    if (part.literal !== undefined) {
      if (part.literal !== segments[i]) return null;
    } else {
      const value = safeDecode(segments[i]);
      if (value === null) return null;
      params[part.param] = value;
    }
  }
  return params;
}

function safeDecode(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

export class Router {
  constructor() {
    this.routes = [];
  }

  add(method, pattern, handler) {
    this.routes.push({
      method: method.toUpperCase(),
      pattern,
      compiled: compile(pattern),
      handler,
    });
    return this;
  }

  get(p, h)    { return this.add('GET', p, h); }
  post(p, h)   { return this.add('POST', p, h); }
  patch(p, h)  { return this.add('PATCH', p, h); }
  delete(p, h) { return this.add('DELETE', p, h); }
  put(p, h)    { return this.add('PUT', p, h); }

  /**
   * @returns {{handler: Function, params: object}|{allowed: string[]}|null}
   *   `allowed` means the path exists but not for this method (→ 405).
   */
  find(method, pathname) {
    const segments = split(pathname);
    const pathMatches = [];

    for (const route of this.routes) {
      const params = matchSegments(route.compiled, segments);
      if (!params) continue;
      pathMatches.push(route.method);
      if (route.method === method.toUpperCase()) {
        return { handler: route.handler, params, pattern: route.pattern };
      }
    }

    if (pathMatches.length) return { allowed: [...new Set(pathMatches)].sort() };
    return null;
  }
}
