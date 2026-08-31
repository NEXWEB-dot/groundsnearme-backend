/**
 * The route table.
 *
 * Order matters: literal paths are registered before their `:param` siblings
 * (`/bookings/mine` before `/bookings/:id`) because the matcher returns the
 * first hit.
 *
 * Everything is under /v1 so the player site, the owner dashboard and the admin
 * views can be versioned independently of each other later.
 */

import { Router } from './lib/router.js';
import * as pub from './routes/public.js';
import * as me from './routes/me.js';
import * as bookings from './routes/bookings.js';
import * as games from './routes/matchmaking.js';
import * as owner from './routes/owner.js';
import * as adminGrounds from './routes/admin-grounds.js';
import * as adminOps from './routes/admin-ops.js';
import * as finance from './routes/finance.js';

export function buildRouter() {
  const r = new Router();

  // -- public ---------------------------------------------------------------
  r.get('/v1/health', pub.health);
  r.get('/v1/areas', pub.listAreas);
  r.get('/v1/grounds', pub.listGrounds);
  r.get('/v1/grounds/:ref/availability', pub.getAvailability);
  r.get('/v1/grounds/:ref', pub.getGround);
  r.get('/v1/matchmaking/games', games.listGames);

  // -- signed-in player -----------------------------------------------------
  r.get('/v1/me', me.getMe);
  r.patch('/v1/me', me.updateMe);

  r.post('/v1/bookings', bookings.createBooking);
  r.get('/v1/bookings/mine', bookings.listMyBookings);
  r.get('/v1/bookings/:id', bookings.getBooking);
  r.post('/v1/bookings/:id/cancel', bookings.cancelBooking);
  r.patch('/v1/bookings/:id/status', bookings.setBookingStatus);

  r.post('/v1/matchmaking/games', games.createGame);
  r.post('/v1/matchmaking/games/:id/interest', games.joinGame);
  r.patch('/v1/matchmaking/interests/:id', games.setInterestStatus);

  // -- owner dashboard ------------------------------------------------------
  r.get('/v1/owner/grounds', owner.myGrounds);
  r.get('/v1/owner/grounds/:id', owner.myGround);
  r.patch('/v1/owner/grounds/:id', owner.updateMyGround);
  r.put('/v1/owner/grounds/:id/hours', owner.setMyHours);
  r.post('/v1/owner/grounds/:id/closures', owner.addMyClosure);
  r.delete('/v1/owner/grounds/:id/closures/:closureId', owner.deleteMyClosure);
  r.get('/v1/owner/bookings', owner.myBookings);
  r.post('/v1/owner/bookings', owner.createManualBooking);
  r.get('/v1/owner/subscriptions', owner.mySubscriptions);

  // -- internal admin -------------------------------------------------------
  r.get('/v1/admin/grounds', adminGrounds.listGrounds);
  r.post('/v1/admin/grounds', adminGrounds.createGround);
  r.get('/v1/admin/grounds/:id', adminGrounds.getGround);
  r.patch('/v1/admin/grounds/:id', adminGrounds.updateGround);
  r.post('/v1/admin/grounds/:id/images', adminGrounds.uploadImage);
  r.patch('/v1/admin/grounds/:id/images', adminGrounds.reorderImages);
  r.delete('/v1/admin/grounds/:id/images', adminGrounds.removeImage);

  r.get('/v1/admin/bookings', adminOps.listBookings);
  r.get('/v1/admin/leads', adminOps.listLeads);
  r.post('/v1/admin/leads', adminOps.createLead);
  r.patch('/v1/admin/leads/:id', adminOps.updateLead);
  r.get('/v1/admin/subscriptions', adminOps.listSubscriptions);
  r.post('/v1/admin/subscriptions', adminOps.createSubscription);
  r.post('/v1/admin/subscriptions/open-cycle', adminOps.openSubscriptionCycle);
  r.patch('/v1/admin/subscriptions/:id', adminOps.updateSubscription);
  r.get('/v1/admin/users', adminOps.listUsers);
  r.patch('/v1/admin/users/:id/role', adminOps.setUserRole);

  // -- private finance (superadmin only) ------------------------------------
  r.get('/v1/finance/overview', finance.overview);
  r.get('/v1/finance/ledger', finance.ledger);
  r.get('/v1/finance/audit', finance.auditLog);

  return r;
}
