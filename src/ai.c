/*
 * NIGHTFALL — the monster's brain and the sanity/dread system.
 *
 * Three horrors share this file's perception/chase logic, branching on
 * mon_type: the Stalker (sight + sound), the blind Listener (sound only,
 * sharp ears), and the Watcher (freezes while seen, rushes the instant you
 * look away). update_fear drains/restores sanity and drives the purely
 * visual hallucination systems (phantom Stalker, dropped-in vision flashes).
 */
#include "game.h"

int    mon_sees = 0;
double phantomX = 0, phantomY = 0;      /* hallucinated Stalker position */
double phantom_t = 0.0;                  /* time the apparition lingers   */
double phantom_timer = 10.0;             /* countdown to the next one     */
double whisper_timer = 0.0, event_timer = 0.0, surge = 0.0;

int    mon_state = AI_WANDER;
int    tgtX, tgtY;
double lastKnownX, lastKnownY;
double hunt_recalc = 0.0, search_time = 0.0;

/* a lingering sound the monster can be lured toward: running feet, a cracked
 * chest, a struck match. It investigates the loudest recent one even when it
 * never saw or directly heard you -- so noise draws it, and you can bait it. */
double noiseX, noiseY, noise_t = 0.0;
void make_noise(double x, double y, double ttl) {
    if (ttl >= noise_t) { noiseX = x; noiseY = y; noise_t = ttl; }
}

int    mon_type = MON_STALKER;
double reveal_t = 0.0;           /* floor-entry warning countdown */
double growl_timer = 0.0;

/* is the monster inside the player's view cone with a clear line of sight?
 * (used by the Watcher, which freezes the instant you look its way).        */
static int player_sees_monster(void) {
    double dx = monX - posX, dy = monY - posY, d = sqrt(dx * dx + dy * dy);
    if (d < 0.7) return 1;                             /* point blank — you feel it */
    double fx = cos(yaw), fy = sin(yaw);
    if ((dx * fx + dy * fy) / d < 0.42) return 0;      /* outside ~65 deg of centre */
    return has_los(posX, posY, monX, monY);
}
static void update_monster(double dt) {
    int cx = (int)monX, cy = (int)monY, best = gdist[cy][cx], bx = cx, by = cy;
    int dx[] = {0, 0, -1, 1}, dy[] = {-1, 1, 0, 0};
    for (int k = 0; k < 4; k++) {
        int nx = cx + dx[k], ny = cy + dy[k];
        if (is_open(nx, ny) && gdist[ny][nx] < best) { best = gdist[ny][nx]; bx = nx; by = ny; }
    }
    double tx = bx + 0.5, ty = by + 0.5, vx = tx - monX, vy = ty - monY;
    double len = sqrt(vx * vx + vy * vy);
    double spd = mon_speed;
    if (mon_type == MON_WATCHER) {
        if (player_sees_monster()) return;             /* frozen while watched */
        spd = mon_speed * 2.3;                         /* but rushes the moment you look away */
    } else if (mon_state == AI_HUNT) {
        /* it surges when hunting you at close range — a terrifying final lunge */
        double pd = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
        if (pd < 3.0) spd *= 1.0 + (3.0 - pd) / 3.0 * 0.55;
    }
    if (len > 1e-4) { double step = spd * dt; if (step > len) step = len;
        monX += vx / len * step; monY += vy / len * step; }
}
void update_ai(double dt, int moving, int sprinting) {
    double d = sqrt((posX - monX) * (posX - monX) + (posY - monY) * (posY - monY));
    int sensed = 0; mon_sees = 0;
    if (noise_t > 0.0) noise_t -= dt;
    /* running is loud: it keeps refreshing a trail at your feet that the
     * monster will chase to, even from across the floor. Walking is silent. */
    if (sprinting && moving && !hidden) make_noise(posX, posY, 1.3);
    /* low sanity = ragged panic breathing: the Stalker hears you from farther */
    double dread = 1.0 - sanity;
    double dd = (depth - 1) < 12 ? (depth - 1) : 12;         /* it grows keener with depth */
    double hear_walk = HEAR_WALK * (1.0 + dread * 0.6 + dd * 0.03);
    double hear_run  = HEAR_RUN  * (1.0 + dread * 0.4 + dd * 0.02);
    double see_range = SEE_RANGE * (1.0 + dd * 0.02);
    if (match_burn > 0.0) see_range *= 1.9;                  /* the glow gives you away */
    if (!hidden) {
        if (mon_type == MON_WATCHER) {
            sensed = 1;                                   /* it always knows — it just can't move while watched */
        } else if (mon_type == MON_LISTENER) {            /* blind: sound only, but sharp ears */
            double hw = HEAR_WALK * 2.4 * (1.0 + dread * 0.5) * (1.0 + dd * 0.03);
            double hr = HEAR_RUN  * 1.9 * (1.0 + dread * 0.3);
            if (moving && d < hw) sensed = 1;
            else if (sprinting && moving && d < hr) sensed = 1;
        } else {                                          /* STALKER: sight + sound */
            if (d < see_range && has_los(monX, monY, posX, posY)) { sensed = 1; mon_sees = 1; }
            else if (moving && d < hear_walk) sensed = 1;
            else if (sprinting && moving && d < hear_run) sensed = 1;
        }
    }
    if (sensed) {
        if (mon_state != AI_HUNT && mon_type != MON_WATCHER) {  /* just caught your trail */
            if (snd_roar) {
                Mix_VolumeChunk(snd_roar, (int)(55 + 73 * (1.0 - fmin(d, 12.0) / 12.0)));
                Mix_PlayChannel(6, snd_roar, 0);
                play_positional(6, monX, monY);
            }
            growl_timer = 5.5 + frand() * 2.0;            /* let the long roar breathe */
        }
        mon_state = AI_HUNT; lastKnownX = posX; lastKnownY = posY;
        hunt_recalc -= dt;
        if (hunt_recalc <= 0 || tgtX != (int)posX || tgtY != (int)posY) {
            set_target((int)posX, (int)posY); hunt_recalc = 0.2;
        }
        growl_timer -= dt;                                /* ragged snarls as it chases (the Watcher is silent) */
        if (growl_timer <= 0) {
            if (snd_growl && mon_type != MON_WATCHER) {
                Mix_VolumeChunk(snd_growl, (int)(40 + 68 * (1.0 - fmin(d, 12.0) / 12.0)));
                Mix_PlayChannel(7, snd_growl, 0);         /* own channel, won't cut the roar */
                play_positional(7, monX, monY);
            }
            growl_timer = 1.8 + frand() * 2.4;
        }
    } else {
        if (mon_state == AI_HUNT) {
            mon_state = AI_SEARCH; search_time = 8.0;
            int tx = (int)lastKnownX, ty = (int)lastKnownY; double bestd = 3.0;
            for (int i = 0; i < NUM_LOCKERS; i++) {
                double ld = fabs(lockers[i].x - lastKnownX) + fabs(lockers[i].y - lastKnownY);
                if (ld < bestd) { bestd = ld; tx = (int)lockers[i].x; ty = (int)lockers[i].y; }
            }
            set_target(tx, ty);
        }
        /* investigate a fresh noise (running feet, a cracked chest, a match)
         * within earshot — head to it and search there, even if it never sensed
         * you directly. Its ears grow keener the deeper you go, so on lower
         * floors a careless sound carries the width of the whole level.        */
        double notice = 11.0 + dd * 0.9;
        if (noise_t > 0.0 && mon_type != MON_WATCHER &&
            fabs(noiseX - monX) + fabs(noiseY - monY) < notice) {
            int nx = (int)noiseX, ny = (int)noiseY;
            if (nx != (int)monX || ny != (int)monY) {
                if (mon_state != AI_SEARCH || tgtX != nx || tgtY != ny) {
                    mon_state = AI_SEARCH; set_target(nx, ny);
                }
                if (search_time < 3.0) search_time = 3.0;
            }
        }
        if (mon_state == AI_SEARCH) {
            search_time -= dt;
            if (((int)monX == tgtX && (int)monY == tgtY) || search_time <= 0) { mon_state = AI_WANDER; pick_wander(); }
        } else if (mon_state == AI_WANDER) {
            if ((int)monX == tgtX && (int)monY == tgtY) pick_wander();
        }
    }
    update_monster(dt);
}

void update_fear(double dt) {
    if (reveal_t > 0.0) reveal_t -= dt;                      /* floor-entry warning fades */
    double dd = (depth - 1) < 12 ? (depth - 1) : 12;         /* deeper = mind frays faster */
    double drain = 0.004 + dd * 0.0025 + tension * 0.05 + (mon_state == AI_HUNT ? 0.03 : 0.0) + (mon_sees ? 0.10 : 0.0);
    if (tension < 0.12 && mon_state != AI_HUNT) sanity += dt * 0.02;
    sanity -= dt * drain;
    /* a lit match is a small comfort against the dark -- it steadies the mind */
    if (match_burn > 0.0) { match_burn -= dt; sanity += dt * 0.03; }
    if (sanity < 0) sanity = 0;
    if (sanity > 1) sanity = 1;
    double dread = 1.0 - sanity;
    whisper_timer -= dt;
    if (whisper_timer <= 0) {
        if (snd_whisper) { Mix_VolumeChunk(snd_whisper, (int)(25 + 80 * dread + 20 * tension));
            Mix_PlayChannel(5, snd_whisper, 0); }
        whisper_timer = 3.0 + sanity * 16.0 - tension * 4.0 + frand() * 4.0;
        if (whisper_timer < 2.0) whisper_timer = 2.0;
    }
    if (surge > 0) surge -= dt;
    event_timer -= dt;
    if (event_timer <= 0) {
        surge = 0.35 + frand() * 0.5;
        event_timer = 6.0 + sanity * 18.0 - tension * 5.0 + frand() * 6.0;
        if (event_timer < 3.0) event_timer = 3.0;
    }

    /* hallucinations: when your mind frays, the Stalker appears where it is
     * not -- down the corridor you're facing -- then is gone. Purely visual. */
    if (phantom_t > 0.0) phantom_t -= dt;
    phantom_timer -= dt;
    if (phantom_timer <= 0.0) {
        phantom_timer = 6.0 + frand() * 9.0 - dread * 4.0;
        if (phantom_timer < 3.0) phantom_timer = 3.0;
        if (dread > 0.35 && mon_state != AI_HUNT && phantom_t <= 0.0) {
            double fx = cos(yaw), fy = sin(yaw), best = 0.0;
            for (double s = 2.0; s <= 7.0; s += 0.5) {
                if (!is_open((int)(posX + fx * s), (int)(posY + fy * s))) break;
                phantomX = posX + fx * s; phantomY = posY + fy * s; best = s;
            }
            if (best >= 2.0) {
                phantom_t = 0.45 + frand() * 0.5;
                if (snd_whisper) { Mix_VolumeChunk(snd_whisper, 110); Mix_PlayChannel(5, snd_whisper, 0); }
            }
        }
    }

    if (screamer_t > 0.0) screamer_t -= dt;      /* the chest jump-scare decays */
    /* dropped-in hallucination images flash over the screen as dread deepens */
    if (vision_t > 0.0) vision_t -= dt;
    vision_timer -= dt;
    if (vision_timer <= 0.0) {
        vision_timer = 9.0 + frand() * 12.0 - dread * 6.0;
        if (vision_timer < 4.0) vision_timer = 4.0;
        if (nvisions > 0 && dread > 0.45 && vision_t <= 0.0) {
            vision_idx = rand() % nvisions;
            vision_t = VIS_DUR;
            if (snd_scare) { Mix_VolumeChunk(snd_scare, 48); Mix_PlayChannel(4, snd_scare, 0); }
        }
    }
}
