import { createHandler } from '../_shared/core.js';
Deno.serve(createHandler('create-application', { env: Deno.env.toObject() }));
