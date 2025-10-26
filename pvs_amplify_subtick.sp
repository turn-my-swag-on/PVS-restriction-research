```c
// pvs_amplify.sp - CS2 SourceMod Plugin (Research/Proof-of-Concept)

#include <sourcemod>
#include <sdktools>

#define MAX_PLAYERS 64

public Plugin:myinfo = 
{
    name = "Turn-my-swag-on",
    author = "Turn-my-swag-on",
    description = "Server-side LOS-based spotting plugin for CS2 (64Hz subtick adapted, research-safe).",
    version = "1.0",
    url = "https://github.com/turn-my-swag-on/PVS-restriction-research/"
};

// ConVars
new Handle:g_hCheckInterval;
new Handle:g_hBroadcastInterval;
new Handle:g_hMaxLOSSamples;
new Handle:g_hMaxChecksPerTick;
new Handle:g_hSpotExpiry;
new Handle:g_hDistanceCull;
new Handle:g_hFOVCos;

// Spotted cache
new bool:g_bSpotted[MAX_PLAYERS+1][MAX_PLAYERS+1];

public OnPluginStart()
{
    g_hCheckInterval = CreateConVar("pvsamp_check_interval", "0.12", "Interval in seconds for LOS checks");
    g_hBroadcastInterval = CreateConVar("pvsamp_broadcast_interval", "0.25", "Interval in seconds to broadcast spotted enemies");
    g_hMaxLOSSamples = CreateConVar("pvsamp_max_los_samples", "4", "Number of ray samples per target");
    g_hMaxChecksPerTick = CreateConVar("pvsamp_max_checks_per_tick", "256", "Maximum LOS checks per tick");
    g_hSpotExpiry = CreateConVar("pvsamp_spot_expiry", "2.5", "Duration in seconds a spot persists");
    g_hDistanceCull = CreateConVar("pvsamp_distance_cull", "1400.0", "Max distance for LOS checks");
    g_hFOVCos = CreateConVar("pvsamp_fov_cos", "0.45", "Cosine threshold for FOV culling");

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    CreateTimer(0.05, Timer_CheckLOS, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_CheckLOS(Handle:timer)
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i)) continue;

        for (new j = 1; j <= MAX_PLAYERS; j++)
        {
            if (i == j) continue;
            if (!IsClientInGame(j) || !IsPlayerAlive(j)) continue;

            new Float:pos1[3], pos2[3];
            GetClientAbsOrigin(i, pos1);
            GetClientAbsOrigin(j, pos2);
            if (GetVectorDistance(pos1, pos2) > GetConVarFloat(g_hDistanceCull)) continue;

            new hits = 0;
            new maxSamples = GetConVarInt(g_hMaxLOSSamples);
            for (new s = 0; s < maxSamples; s++)
            {
                if (LineOfSightCheck(i, j)) hits++;
            }

            g_bSpotted[i][j] = (hits > 0);
        }
    }
    return Plugin_Continue;
}

public bool:LineOfSightCheck(client, target)
{
    new Float:vecStart[3], vecEnd[3];
    GetClientEyePosition(client, vecStart);
    GetClientEyePosition(target, vecEnd);

    return !TestLine(vecStart, vecEnd, MASK_SHOT, target);
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client <= 0) return;

    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        g_bSpotted[client][i] = false;
        g_bSpotted[i][client] = false;
    }
}

native Float:GetVectorDistance(const Float:v1[3], const Float:v2[3])
{
    return SquareRoot(Pow(v1[0]-v2[0],2.0) + Pow(v1[1]-v2[1],2.0) + Pow(v1[2]-v2[2],2.0));
}
```
