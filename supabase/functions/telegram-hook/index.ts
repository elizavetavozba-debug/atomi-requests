import { createHandler } from '../_shared/core.js';
Deno.serve(createHandler('telegram-hook', { env: Deno.env.toObject() }));
