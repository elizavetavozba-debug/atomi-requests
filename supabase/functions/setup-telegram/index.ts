import { createHandler } from '../_shared/core.js';
Deno.serve(createHandler('setup-telegram', { env: Deno.env.toObject() }));
