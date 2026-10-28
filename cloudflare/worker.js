const LASTFM_ENDPOINT = 'https://ws.audioscrobbler.com/2.0/';
const MAX_BODY_BYTES = 16_384;

const methodParameters = {
  'auth.getToken': [],
  'auth.getSession': ['token'],
  'track.updateNowPlaying': [
    'sk',
    'artist',
    'track',
    'album',
    'albumArtist',
    'mbid',
    'trackNumber',
    'duration',
  ],
  'track.scrobble': [
    'sk',
    'artist[0]',
    'track[0]',
    'album[0]',
    'albumArtist[0]',
    'mbid[0]',
    'trackNumber[0]',
    'duration[0]',
    'timestamp[0]',
    'chosenByUser[0]',
  ],
};

export default {
  async fetch(request, env) {
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Cache-Control': 'no-store',
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (!env.LASTFM_RATE_LIMITER) {
      return json(
        { error: 'Worker rate limiting is not configured.' },
        503,
        corsHeaders,
      );
    }
    const clientIp = request.headers.get('CF-Connecting-IP');
    if (!clientIp) {
      return json({ error: 'Request could not be verified.' }, 403, corsHeaders);
    }
    const { success } = await env.LASTFM_RATE_LIMITER.limit({ key: clientIp });
    if (!success) {
      return json({ error: 'Too many requests. Try again shortly.' }, 429, corsHeaders);
    }

    const url = new URL(request.url);
    if (
      !['/authorize', '/api'].includes(url.pathname) ||
      request.method !== 'POST'
    ) {
      return json({ error: 'Not found.' }, 404, corsHeaders);
    }

    if (!env.LASTFM_API_KEY || !env.LASTFM_SHARED_SECRET) {
      return json({ error: 'Worker is not configured.' }, 503, corsHeaders);
    }
    if (Number(request.headers.get('content-length') || 0) > MAX_BODY_BYTES) {
      return json({ error: 'Request is too large.' }, 413, corsHeaders);
    }
    if (!request.headers.get('content-type')?.includes('application/json')) {
      return json({ error: 'Expected application/json.' }, 415, corsHeaders);
    }

    const rawBody = await request.arrayBuffer();
    if (rawBody.byteLength > MAX_BODY_BYTES) {
      return json({ error: 'Request is too large.' }, 413, corsHeaders);
    }

    let payload;
    try {
      payload = JSON.parse(new TextDecoder().decode(rawBody));
    } catch {
      return json({ error: 'Invalid JSON.' }, 400, corsHeaders);
    }

    if (url.pathname === '/authorize') {
      const token = payload?.token;
      if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{1,256}$/.test(token)) {
        return json({ error: 'Invalid authorization token.' }, 400, corsHeaders);
      }
      const authorizationUrl = new URL('https://www.last.fm/api/auth');
      authorizationUrl.searchParams.set('api_key', env.LASTFM_API_KEY);
      authorizationUrl.searchParams.set('token', token);
      return json({ url: authorizationUrl.toString() }, 200, corsHeaders);
    }

    const { method, parameters } = payload || {};
    if (
      typeof method !== 'string' ||
      !Object.hasOwn(methodParameters, method) ||
      !parameters ||
      typeof parameters !== 'object' ||
      Array.isArray(parameters)
    ) {
      return json({ error: 'Invalid request.' }, 400, corsHeaders);
    }

    const allowedParameters = methodParameters[method];
    const submittedKeys = Object.keys(parameters);
    if (
      submittedKeys.some((key) => !allowedParameters.includes(key)) ||
      submittedKeys.some(
        (key) =>
          typeof parameters[key] !== 'string' || parameters[key].length > 1024,
      )
    ) {
      return json({ error: 'Invalid request parameters.' }, 400, corsHeaders);
    }

    if (method === 'auth.getSession' && !parameters.token) {
      return json({ error: 'Authorization token is required.' }, 400, corsHeaders);
    }
    const artist = parameters['artist[0]'] || parameters.artist;
    const track = parameters['track[0]'] || parameters.track;
    if (method.startsWith('track.') && (!parameters.sk || !artist || !track)) {
      return json({ error: 'Session, artist, and track are required.' }, 400, corsHeaders);
    }
    if (method === 'track.scrobble' && !/^\d+$/.test(parameters['timestamp[0]'] || '')) {
      return json({ error: 'A valid scrobble timestamp is required.' }, 400, corsHeaders);
    }

    const signedParameters = {
      ...parameters,
      api_key: env.LASTFM_API_KEY,
      method,
    };
    const signature = md5(
      Object.keys(signedParameters)
        .sort()
        .map((key) => `${key}${signedParameters[key]}`)
        .join('') + env.LASTFM_SHARED_SECRET,
    );
    const form = new URLSearchParams({
      ...signedParameters,
      api_sig: signature,
      format: 'json',
    });

    try {
      const upstreamUrl = new URL(LASTFM_ENDPOINT);
      const isAuthMethod = method.startsWith('auth.');
      const upstreamResponse = await fetch(
        isAuthMethod ? `${upstreamUrl}?${form}` : upstreamUrl,
        isAuthMethod
          ? {
              headers: { 'User-Agent': 'river Music Player' },
            }
          : {
              method: 'POST',
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'User-Agent': 'river Music Player',
              },
              body: form,
            },
      );
      const body = await upstreamResponse.text();
      return new Response(body, {
        status: upstreamResponse.status,
        headers: {
          ...corsHeaders,
          'Content-Type':
            upstreamResponse.headers.get('content-type') || 'application/json',
        },
      });
    } catch {
      return json({ error: 'Could not reach Last.fm.' }, 502, corsHeaders);
    }
  },
};

function json(body, status, headers) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

function md5(value) {
  const input = new TextEncoder().encode(value);
  const paddedLength = Math.ceil((input.length + 9) / 64) * 64;
  const bytes = new Uint8Array(paddedLength);
  bytes.set(input);
  bytes[input.length] = 0x80;
  const view = new DataView(bytes.buffer);
  const bitLength = input.length * 8;
  view.setUint32(paddedLength - 8, bitLength >>> 0, true);
  view.setUint32(paddedLength - 4, Math.floor(bitLength / 0x100000000), true);

  const shifts = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  const constants = Array.from({ length: 64 }, (_, i) =>
    Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000),
  );
  let a0 = 0x67452301;
  let b0 = 0xefcdab89;
  let c0 = 0x98badcfe;
  let d0 = 0x10325476;

  for (let offset = 0; offset < paddedLength; offset += 64) {
    const words = Array.from({ length: 16 }, (_, i) =>
      view.getUint32(offset + i * 4, true),
    );
    let a = a0;
    let b = b0;
    let c = c0;
    let d = d0;

    for (let i = 0; i < 64; i++) {
      let f;
      let g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }

      const sum = (a + f + constants[i] + words[g]) >>> 0;
      const rotated = (sum << shifts[i]) | (sum >>> (32 - shifts[i]));
      [a, d, c, b] = [d, c, b, (b + rotated) >>> 0];
    }

    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  return [a0, b0, c0, d0]
    .map((word) =>
      Array.from({ length: 4 }, (_, i) =>
        ((word >>> (i * 8)) & 0xff).toString(16).padStart(2, '0'),
      ).join(''),
    )
    .join('');
}
