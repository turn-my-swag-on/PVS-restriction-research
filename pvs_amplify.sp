/**
 * pvs_amplify.sp
 * SourceMod 1.12 (CS2) — tight server-side LOS-based spotting
 *
 * - Aggressive pre-filters: distance, FOV
 * - Multi-sample LOS (head/chest/legs + offsets)
 * - Staggered checks + caching
 * - Team aggregation + compact broadcast (no coords)
 *
 * NOTE:
 * - Replace/verify engine trace functions if your SM build exposes slightly different names.
 * - This plugin intentionally avoids engine internals (no ShouldTransmit or PVS hooks).
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools_trace>
#include <sdkhooks>
#include <math>

public Plugin myinfo =
{
    name = "PVS Amplified (tight)",
    author = "turn-my-swag-on",
    description = "Server-side LOS-based spotted system",
    version = "1.0"
};

/* == Configurable CVars == */
new Handle:gCvar_Enabled;
new Handle:gCvar_CheckInterval;
new Handle:gCvar_BroadcastInterval;
new Handle:gCvar_MaxLosSamples;
new Handle:gCvar_MaxChecksPerTick;
new Handle:gCvar_SpotExpiry;
new Handle:gCvar_DistanceCull;
new Handle:gCvar_FOVCull;

public void OnPluginStart()
{
    gCvar_Enabled = CreateConVar("pvsamp_enabled", "1", "Enable/disable PVS-Amplified spotting", FCVAR_PLUGIN, true, 0.0, true, 1.0);
    gCvar_CheckInterval = CreateConVar("pvsamp_check_interval", "0.08", "Server tick interval to run checks (s)", FCVAR_PLUGIN, true, 0.01, true, 1.0);
    gCvar_BroadcastInterval = CreateConVar("pvsamp_broadcast_interval", "0.20", "How often to broadcast spotted updates (s)", FCVAR_PLUGIN, true, 0.05, true, 2.0);
    gCvar_MaxLosSamples = CreateConVar("pvsamp_max_los_samples", "4", "Max LOS samples per target (head/chest/legs/offset)", FCVAR_PLUGIN, true, 1.0, true, 8.0);
    gCvar_MaxChecksPerTick = CreateConVar("pvsamp_max_checks_per_tick", "512", "Max viewer->target checks per tick (staggered)", FCVAR_PLUGIN, true, 16.0, true, 8192.0);
    gCvar_SpotExpiry = CreateConVar("pvsamp_spot_expiry", "3.0", "Seconds before a spot expires", FCVAR_PLUGIN, true, 0.5, true, 30.0);
    gCvar_DistanceCull = CreateConVar("pvsamp_distance_cull", "1500.0", "Max distance (units) to consider LOS", FCVAR_PLUGIN, true, 200.0, true, 5000.0);
    gCvar_FOVCull = CreateConVar("pvsamp_fov_cos", "0.5", "Dot-product threshold for FOV cull (cos). 0.5 ~= 60deg", FCVAR_PLUGIN, true, -1.0, true, 1.0);

    CreateTimer( GetConVarFloat(gCvar_CheckInterval), Timer_CheckLOS, _, TIMER_REPEAT );
    CreateTimer( GetConVarFloat(gCvar_BroadcastInterval), Timer_Broadcast, _, TIMER_REPEAT );

    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
}

/* == Internal storage == 
   We store:
     - cachedVisibility[viewer][target] = expiry timestamp (float)
     - teamSpotted[team] = dynamic array of (enemyId, expiry, zone)
*/
#define MAXPLAYERS_SM 130
new Float:gCachedVisibility[MAXPLAYERS_SM][MAXPLAYERS_SM]; // default 0.0
new Handle:gTeamSpotted; // Trie: key=team string -> Handle to ArrayList of int triples

/* tick counter for staggering */
new cell:gServerTick = 0;

public Action Timer_CheckLOS( Handle timer )
{
    if (GetConVarInt(gCvar_Enabled) == 0) return Plugin_Continue;

    gServerTick++;
    float now = GetEngineTime();

    int maxChecks = GetConVarInt(gCvar_MaxChecksPerTick);
    int checksDone = 0;
    int viewers[128]; int vcount = 0;
    int candidates[128]; int ccount = 0;

    // Build viewers list (alive players)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        viewers[vcount++] = i;
    }

    // Make candidate list (alive players)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;
        candidates[ccount++] = i;
    }

    // Stagger: compute start indices based on tick so we don't check everything each tick
    int viewerStart = gServerTick % ((vcount == 0) ? 1 : vcount);
    int candStart = gServerTick % ((ccount == 0) ? 1 : ccount);

    // Loop viewers (staggered)
    for (int vi = 0; vi < vcount && checksDone < maxChecks; vi++)
    {
        int vIndex = (viewerStart + vi) % vcount;
        int viewer = viewers[vIndex];

        if (IsClientObserver(viewer)) continue; // skip observers or change policy

        float vEye[3]; GetClientEyePosition(viewer, vEye);
        float vForward[3];
        GetClientForwardVector(viewer, vForward); // helper declared below

        int vTeam = GetClientTeam(viewer);

        // Limit targets per viewer per tick:
        int perViewerCap = Max(1, maxChecks / Max(1, vcount)); // distribute budget
        int localChecks = 0;

        for (int ci = 0; ci < ccount && localChecks < perViewerCap && checksDone < maxChecks; ci++)
        {
            int tIndex = (candStart + ci) % ccount;
            int target = candidates[tIndex];
            if (target == viewer) continue;
            if (GetClientTeam(target) == vTeam) continue; // ignore teammates; optionally include

            // Quick distance cull
            float tOrigin[3]; GetClientAbsOrigin(target, tOrigin);
            float dist2 = GetVectorDistanceSquared(vEye, tOrigin);
            float maxDist = GetConVarFloat(gCvar_DistanceCull);
            if (dist2 > (maxDist * maxDist)) continue;

            // Quick FOV cull using dot product
            float toTarget[3];
            toTarget[0] = tOrigin[0] - vEye[0];
            toTarget[1] = tOrigin[1] - vEye[1];
            toTarget[2] = tOrigin[2] - vEye[2];
            NormalizeVector(toTarget);
            float dot = DotProduct(vForward, toTarget);
            float fovThresh = GetConVarFloat(gCvar_FOVCull);
            if (dot < fovThresh) continue;

            // Check cache first: if already visible and not expired, no need for trace
            if (gCachedVisibility[viewer][target] > now)
            {
                // refresh team spotted entry
                MarkTeamSpotted(vTeam, target, now, GetConVarFloat(gCvar_SpotExpiry));
                localChecks++; checksDone++;
                continue;
            }

            // Do multi-sample LOS traces (head/chest/legs + small offsets)
            bool visible = false;
            int samples = Min(GetConVarInt(gCvar_MaxLosSamples), 6);
            float sample[3];

            for (int s = 0; s < samples; s++)
            {
                GetTargetSamplePosition(target, s, sample); // helper defined below

                if (DoTraceLine(vEye, sample, viewer, target))
                {
                    visible = true;
                    break;
                }
            }

            if (visible)
            {
                // Cache it for short time (spot expiry or a fraction)
                gCachedVisibility[viewer][target] = now + Max(0.25, GetConVarFloat(gCvar_SpotExpiry));
                MarkTeamSpotted(vTeam, target, now, GetConVarFloat(gCvar_SpotExpiry));
            }
            else
            {
                // ensure cache cleared
                gCachedVisibility[viewer][target] = 0.0;
            }

            localChecks++; checksDone++;
        } // candidates loop
    } // viewers loop

    return Plugin_Continue;
}

/* === Broadcast compact spotted messages to players === */
public Action Timer_Broadcast( Handle timer )
{
    if (GetConVarInt(gCvar_Enabled) == 0) return Plugin_Continue;
    float now = GetEngineTime();

    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int team = StringToInt(key);
        // Build compact list of entries
        int len = GetArraySize(arr);
        if (len == 0) continue;

        // For each player on team, send the same compact broadcast
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;
            if (GetClientTeam(i) != team) continue;

            // Start a custom usermessage "pvs_spotted" (use StartMessage API)
            StartMessage("pvs_spotted", i);
            WriteFloatFloat(now); // timestamp
            WriteByte(len); // number of entries (max 255)
            // Each entry: short enemyId, float expiry, short zone
            for (int idx = 0; idx < len; idx++)
            {
                int enemyId = GetArrayCell(arr, idx, 0);
                float expiry = GetArrayCellFloat(arr, idx, 1);
                int zone = GetArrayCell(arr, idx, 2);
                WriteShort(enemyId);
                WriteFloat(expiry);
                WriteShort(zone);
            }
            EndMessage();
        }
    }
    CloseHandle(iter);

    // Important: expire old entries after broadcast to keep arrs small
    ExpireTeamSpots(now);

    return Plugin_Continue;
}

/* === Helpers: storage & manipulation === */
public void MarkTeamSpotted(int team, int enemy, float now, float expiryDuration)
{
    if (team <= 0) return;
    char key[16];
    IntToString(team, key, sizeof(key));
    Handle arr = TrieGetHandle(gTeamSpotted, key);
    if (arr == INVALID_HANDLE)
    {
        arr = CreateArray(3); // store triples: enemyId, expiry (float), zone
        TrieSetHandle(gTeamSpotted, key, arr);
    }

    // Search existing; if present refresh expiry
    int len = GetArraySize(arr);
    for (int i = 0; i < len; i++)
    {
        int storedId = GetArrayCell(arr, i, 0);
        if (storedId == enemy)
        {
            SetArrayCell(arr, i, 1, FloatToCell(now + expiryDuration));
            return;
        }
    }

    // Not present -> push triple
    PushArrayCell(arr, enemy);
    PushArrayCell(arr, FloatToCell(now + expiryDuration));
    PushArrayCell(arr, 0); // zone=0 for now; implement zone mapping for map-specific
}

public void ExpireTeamSpots(float now)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        // iterate backwards: each triple is 3 cells
        int len = GetArraySize(arr);
        // len must be multiple of 3
        for (int i = len - 3; i >= 0; i -= 3)
        {
            float expiry = CellToFloat( GetArrayCell(arr, i + 1) );
            if (expiry < now)
            {
                // remove triple (enemy, expiry, zone)
                RemoveArrayCell(arr, i + 2);
                RemoveArrayCell(arr, i + 1);
                RemoveArrayCell(arr, i + 0);
            }
        }
    }
    CloseHandle(iter);
}

public void RemovePlayerFromAllTeamSpots(int player)
{
    Handle iter = CreateTrieIterator(gTeamSpotted);
    char key[16];
    while (TrieIteratorNext(iter, key, sizeof(key)))
    {
        Handle arr = TrieGetHandle(gTeamSpotted, key);
        if (arr == INVALID_HANDLE) continue;

        int len = GetArraySize(arr);
        for (int i = len - 3; i >= 0; i -= 3)
        {
            int storedId = GetArrayCell(arr, i + 0);
            if (storedId == player)
            {
                RemoveArrayCell(arr, i + 2);
                RemoveArrayCell(arr, i + 1);
                RemoveArrayCell(arr, i + 0);
            }
        }
    }
    CloseHandle(iter);
}

/* === Utilities & Trace helpers === */
bool DoTraceLine(float start[3], float end[3], int viewer, int expectedTarget)
{
    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter, viewer);
    bool hit = TR_DidHit(tr);
    int ent = TR_GetEntityIndex(tr);
    CloseHandle(tr);
    // If we hit something and it's NOT the expected target -> blocked
    if (hit && ent != expectedTarget) return false;
    return true;
}

/* Trace filter: ignore viewer, allow world and everything else */
public bool TraceFilter(int entIndex, int contentsMask, any data)
{
    int viewer = data;
    if (entIndex == viewer) return false;
    return true;
}

/* Provide sample positions on target: 0=head,1=chest,2=feet,3.. offsets */
void GetTargetSamplePosition(int target, int sampleIndex, float out[3])
{
    GetClientEyePosition(target, out); // head
    if (sampleIndex == 0) return;

    GetClientAbsOrigin(target, out); // origin
    if (sampleIndex == 1) { out[2] += 40.0; return; } // chest
    if (sampleIndex == 2) { out[2] += 10.0; return; } // hips/legs
    // offsets: small left/right/up jitter to bypass small blockers
    if (sampleIndex == 3) { out[0] += 12.0; out[1] += 0.0; out[2] += 20.0; return; }
    if (sampleIndex == 4) { out[0] -= 12.0; out[1] += 0.0; out[2] += 20.0; return; }
    if (sampleIndex == 5) { out[0] += 0.0; out[1] += 12.0; out[2] += 20.0; return; }
}

/* Get forward vector of client (approx) */
void GetClientForwardVector(int client, float out[3])
{
    float ang[3];
    GetClientEyeAngles(client, ang);
    float pitch = ang[0] * (M_PI / 180.0);
    float yaw = ang[1] * (M_PI / 180.0);
    out[0] = Cos(pitch) * Cos(yaw);
    out[1] = Cos(pitch) * Sin(yaw);
    out[2] = -Sin(pitch);
    NormalizeVector(out);
}

/* Vector helpers */
float GetVectorDistanceSquared(float a[3], float b[3])
{
    float dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return dx*dx + dy*dy + dz*dz;
}

void NormalizeVector(float v[3])
{
    float len = SquareRoot(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    if (len <= 0.00001) { v[0]=1.0; v[1]=0.0; v[2]=0.0; return; }
    v[0] /= len; v[1] /= len; v[2] /= len;
}

float DotProduct(const float a[3], const float b[3])
{
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

/* Events */
public void Event_PlayerDeath(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);

    // clear cache entries for dead player
    for (int v = 1; v <= MaxClients; v++)
    {
        gCachedVisibility[v][client] = 0.0;
        gCachedVisibility[client][v] = 0.0;
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontbroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    RemovePlayerFromAllTeamSpots(client);
    for (int v = 1; v <= MaxClients; v++)
    {
        gCachedVisibility[v][client] = 0.0;
        gCachedVisibility[client][v] = 0.0;
    }
}
