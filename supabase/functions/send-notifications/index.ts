import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

type QueueItem = {
  id: string;
  employee_id: string | null;
  branch_num: number | null;
  title: string;
  body: string;
  data: Record<string, unknown> | string | null;
  attempts: number | null;
};

type Installation = {
  id: string;
  installation_id: string;
  employee_id: string;
  fcm_token: string | null;
  pushy_token: string | null;
  preferred_provider: string | null;
  firebase_failures: number | null;
  pushy_failures: number | null;
};

type Employee = {
  id: string;
  branch_num: number | null;
  role: string | null;
  can_manage_all_branches: boolean | null;
};

type DeliveryOutcome = {
  status: "sent" | "failed" | "skipped";
  provider?: "firebase" | "pushy";
  providerMessageId?: string;
  error?: string;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const firebaseJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") ?? "";
const pushyApiKey = Deno.env.get("PUSHY_SECRET_API_KEY") ?? "";

let firebaseAccessToken: string | null = null;

serve(async () => {
  if (!supabaseUrl || !serviceRoleKey) {
    return json({ ok: false, error: "Missing Supabase secrets" }, 500);
  }
  if (!firebaseJson && !pushyApiKey) {
    return json({ ok: false, error: "At least one notification provider must be configured" }, 500);
  }

  await generateAttendanceReminders();

  const now = encodeURIComponent(new Date().toISOString());
  const queue = await supabaseGet<QueueItem[]>(
    `/rest/v1/ansar_notification_queue?status=in.(pending,retrying)&or=(next_attempt_at.is.null,next_attempt_at.lte.${now})&select=id,employee_id,branch_num,title,body,data,attempts&order=created_at.asc&limit=25`,
  );

  let sent = 0;
  let retrying = 0;
  let failed = 0;

  for (const item of queue) {
    try {
      const targets = dedupeInstallations(await getTargetInstallations(item));
      if (targets.length === 0) {
        await scheduleQueueRetry(item, "No active installations matched this notification");
        retrying += 1;
        continue;
      }

      const outcomes: DeliveryOutcome[] = [];
      for (const installation of targets) {
        const existing = await ensureDelivery(item, installation);
        if (existing?.status === "sent") {
          outcomes.push({ status: "sent", provider: existing.provider });
          continue;
        }

        const outcome = await sendToInstallation(item, installation);
        outcomes.push(outcome);
        await saveDelivery(item, installation, outcome, (existing?.attempts ?? 0) + 1);
      }

      const allProcessed = outcomes.every((outcome) => outcome.status === "sent" || outcome.status === "skipped");
      const deliveredAtLeastOnce = outcomes.some((outcome) => outcome.status === "sent");
      if (allProcessed && deliveredAtLeastOnce) {
        await markQueueSent(item.id);
        sent += 1;
      } else if ((item.attempts ?? 0) >= 7) {
        await markQueueFailed(item.id, firstOutcomeError(outcomes));
        failed += 1;
      } else {
        await scheduleQueueRetry(item, firstOutcomeError(outcomes));
        retrying += 1;
      }
    } catch (error) {
      if ((item.attempts ?? 0) >= 7) {
        await markQueueFailed(item.id, String(error));
        failed += 1;
      } else {
        await scheduleQueueRetry(item, String(error));
        retrying += 1;
      }
    }
  }

  return json({ ok: true, processed: queue.length, sent, retrying, failed });
});

async function generateAttendanceReminders() {
  try {
    await supabasePost("/rest/v1/rpc/ansar_generate_attendance_reminders", {});
  } catch (_) {
    // The sender remains compatible until the additive platform migration is applied.
  }
}

function queueData(item: QueueItem): Record<string, unknown> {
  if (item.data && typeof item.data === "object") return item.data;
  if (typeof item.data === "string") {
    try {
      const decoded = JSON.parse(item.data);
      if (decoded && typeof decoded === "object") return decoded;
    } catch (_) {
      // Invalid optional payload data becomes an empty object.
    }
  }
  return {};
}

async function getTargetInstallations(item: QueueItem): Promise<Installation[]> {
  const data = queueData(item);
  const senderId = typeof data.sender_id === "string" ? data.sender_id : null;
  const installations = await loadInstallations();

  if (item.employee_id) {
    return installations.filter((device) => device.employee_id === item.employee_id && device.employee_id !== senderId);
  }

  if (item.branch_num !== null && item.branch_num !== undefined) {
    const employees = await loadEmployees();
    const allowed = new Set(
      employees
        .filter((employee) =>
          employee.branch_num === item.branch_num ||
          employee.role === "admin" ||
          employee.can_manage_all_branches === true
        )
        .map((employee) => employee.id),
    );
    if (senderId) allowed.delete(senderId);
    return installations.filter((device) => allowed.has(device.employee_id));
  }

  return installations.filter((device) => device.employee_id !== senderId);
}

async function loadInstallations(): Promise<Installation[]> {
  try {
    const installations = await supabaseGet<Installation[]>(
      "/rest/v1/ansar_device_installations?is_active=eq.true&select=id,installation_id,employee_id,fcm_token,pushy_token,preferred_provider,firebase_failures,pushy_failures",
    );
    return installations.filter((device) => Boolean(device.fcm_token || device.pushy_token));
  } catch (_) {
    const legacy = await supabaseGet<Array<{ id: string; employee_id: string; token: string }>>(
      "/rest/v1/ansar_device_tokens?is_active=eq.true&select=id,employee_id,token",
    );
    return legacy.map((device) => ({
      id: device.id,
      installation_id: `legacy:${device.id}`,
      employee_id: device.employee_id,
      fcm_token: device.token,
      pushy_token: null,
      preferred_provider: "firebase",
      firebase_failures: 0,
      pushy_failures: 0,
    }));
  }
}

async function loadEmployees(): Promise<Employee[]> {
  return await supabaseGet<Employee[]>(
    "/rest/v1/ansar_employees?is_active=eq.true&select=id,branch_num,role,can_manage_all_branches",
  );
}

function dedupeInstallations(devices: Installation[]) {
  const seen = new Set<string>();
  return devices.filter((device) => {
    if (seen.has(device.installation_id)) return false;
    seen.add(device.installation_id);
    return true;
  });
}

async function ensureDelivery(item: QueueItem, installation: Installation) {
  try {
    await supabasePost(
      "/rest/v1/ansar_notification_deliveries?on_conflict=notification_id,installation_id",
      {
        notification_id: item.id,
        installation_id: installation.id,
        employee_id: installation.employee_id,
        status: "pending",
      },
      "resolution=ignore-duplicates,return=minimal",
    );
    const rows = await supabaseGet<Array<{ status: "sent" | "failed" | "skipped" | "pending"; provider?: "firebase" | "pushy"; attempts: number }>>(
      `/rest/v1/ansar_notification_deliveries?notification_id=eq.${encodeURIComponent(item.id)}&installation_id=eq.${encodeURIComponent(installation.id)}&select=status,provider,attempts&limit=1`,
    );
    return rows[0] ?? null;
  } catch (_) {
    return null;
  }
}

async function sendToInstallation(item: QueueItem, installation: Installation): Promise<DeliveryOutcome> {
  let firebaseError = "";
  if (installation.fcm_token && firebaseJson) {
    try {
      const providerMessageId = await sendFirebase(item, installation.fcm_token);
      await updateInstallationSuccess(installation, "firebase");
      return { status: "sent", provider: "firebase", providerMessageId };
    } catch (error) {
      firebaseError = String(error);
      await updateFirebaseFailure(installation, firebaseError);
    }
  }

  const shouldUsePushy =
    !installation.fcm_token ||
    !firebaseJson ||
    isUnregisteredFirebase(firebaseError) ||
    (installation.firebase_failures ?? 0) + 1 >= 2;
  if (installation.pushy_token && pushyApiKey && shouldUsePushy) {
    try {
      const providerMessageId = await sendPushy(item, installation.pushy_token);
      await updateInstallationSuccess(installation, "pushy");
      return { status: "sent", provider: "pushy", providerMessageId };
    } catch (error) {
      const pushyError = String(error);
      await updatePushyFailure(installation, pushyError);
      return { status: "failed", provider: "pushy", error: [firebaseError, pushyError].filter(Boolean).join(" | ") };
    }
  }

  if (!installation.fcm_token && !installation.pushy_token) {
    return { status: "skipped", error: "Installation has no active provider token" };
  }
  return { status: "failed", provider: "firebase", error: firebaseError || "No fallback provider is configured" };
}

async function sendFirebase(item: QueueItem, token: string): Promise<string> {
  firebaseAccessToken ??= await getFirebaseAccessToken();
  const serviceAccount = JSON.parse(firebaseJson);
  const data = queueData(item);
  const senderImage =
    typeof data.sender_avatar_url === "string" && data.sender_avatar_url.startsWith("https://")
      ? data.sender_avatar_url
      : null;
  const response = await fetch(`https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${firebaseAccessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      message: {
        token,
        notification: {
          title: item.title,
          body: item.body,
          ...(senderImage ? { image: senderImage } : {}),
        },
        data: stringifyData({ ...data, notification_id: item.id }),
        android: {
          priority: "HIGH",
          collapse_key: `ansar-${item.id}`,
          notification: {
            sound: "default",
            ...(senderImage ? { image: senderImage } : {}),
          },
        },
      },
    }),
  });
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  return payload.name ?? "firebase";
}

async function sendPushy(item: QueueItem, token: string): Promise<string> {
  const data = {
    ...queueData(item),
    notification_id: item.id,
    title: item.title,
    message: item.body,
  };
  const response = await fetch(`https://api.pushy.me/push?api_key=${encodeURIComponent(pushyApiKey)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      to: token,
      data,
      notification: { title: item.title, body: item.body, sound: "default" },
      collapse_key: `ansar-${item.id}`.slice(0, 32),
      time_to_live: 604800,
    }),
  });
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  return payload.id ?? "pushy";
}

function isUnregisteredFirebase(error: string) {
  return error.includes("UNREGISTERED") || error.includes("Requested entity was not found");
}

function isInvalidPushy(error: string) {
  return error.includes("NO_RECIPIENTS") || error.includes("INVALID_PARAM");
}

async function updateFirebaseFailure(installation: Installation, error: string) {
  if (installation.installation_id.startsWith("legacy:")) {
    if (isUnregisteredFirebase(error)) {
      await supabasePatch(`/rest/v1/ansar_device_tokens?id=eq.${encodeURIComponent(installation.id)}`, { is_active: false });
    }
    return;
  }
  await supabasePatch(`/rest/v1/ansar_device_installations?id=eq.${encodeURIComponent(installation.id)}`, {
    firebase_failures: (installation.firebase_failures ?? 0) + 1,
    ...(isUnregisteredFirebase(error) ? { fcm_token: null } : {}),
    updated_at: new Date().toISOString(),
  });
}

async function updatePushyFailure(installation: Installation, error: string) {
  if (installation.installation_id.startsWith("legacy:")) return;
  await supabasePatch(`/rest/v1/ansar_device_installations?id=eq.${encodeURIComponent(installation.id)}`, {
    pushy_failures: (installation.pushy_failures ?? 0) + 1,
    ...(isInvalidPushy(error) ? { pushy_token: null } : {}),
    updated_at: new Date().toISOString(),
  });
}

async function updateInstallationSuccess(installation: Installation, provider: "firebase" | "pushy") {
  if (installation.installation_id.startsWith("legacy:")) return;
  await supabasePatch(`/rest/v1/ansar_device_installations?id=eq.${encodeURIComponent(installation.id)}`, {
    preferred_provider: provider,
    last_success_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    ...(provider === "firebase" ? { firebase_failures: 0 } : { pushy_failures: 0 }),
  });
}

async function saveDelivery(item: QueueItem, installation: Installation, outcome: DeliveryOutcome, attempts: number) {
  try {
    const nextAttemptAt = outcome.status === "failed"
      ? new Date(Date.now() + backoffSeconds(attempts) * 1000).toISOString()
      : null;
    await supabasePatch(
      `/rest/v1/ansar_notification_deliveries?notification_id=eq.${encodeURIComponent(item.id)}&installation_id=eq.${encodeURIComponent(installation.id)}`,
      {
        status: outcome.status,
        provider: outcome.provider ?? null,
        provider_message_id: outcome.providerMessageId ?? null,
        last_error: outcome.error?.slice(0, 1200) ?? null,
        attempts,
        next_attempt_at: nextAttemptAt,
        sent_at: outcome.status === "sent" ? new Date().toISOString() : null,
        updated_at: new Date().toISOString(),
      },
    );
  } catch (_) {
    // Compatibility mode before the delivery table migration is installed.
  }
}

function backoffSeconds(attempt: number) {
  return Math.min(3600, 30 * Math.pow(2, Math.max(0, attempt - 1)));
}

function firstOutcomeError(outcomes: DeliveryOutcome[]) {
  return outcomes.find((outcome) => outcome.error)?.error ?? "Delivery is incomplete";
}

async function scheduleQueueRetry(item: QueueItem, error: string) {
  const attempts = (item.attempts ?? 0) + 1;
  await supabasePatch(`/rest/v1/ansar_notification_queue?id=eq.${encodeURIComponent(item.id)}`, {
    status: "pending",
    attempts,
    next_attempt_at: new Date(Date.now() + backoffSeconds(attempts) * 1000).toISOString(),
    error_message: error.slice(0, 1200),
  });
}

async function markQueueSent(id: string) {
  await supabasePatch(`/rest/v1/ansar_notification_queue?id=eq.${encodeURIComponent(id)}`, {
    status: "sent",
    sent_at: new Date().toISOString(),
    processed_at: new Date().toISOString(),
    next_attempt_at: null,
    error_message: null,
  });
}

async function markQueueFailed(id: string, error: string) {
  await supabasePatch(`/rest/v1/ansar_notification_queue?id=eq.${encodeURIComponent(id)}`, {
    status: "failed",
    processed_at: new Date().toISOString(),
    next_attempt_at: null,
    error_message: error.slice(0, 1200),
  });
}

async function getFirebaseAccessToken(): Promise<string> {
  const serviceAccount = JSON.parse(firebaseJson);
  const now = Math.floor(Date.now() / 1000);
  const assertion = await signJwt(serviceAccount.client_email, serviceAccount.private_key, {
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  return payload.access_token;
}

async function signJwt(clientEmail: string, privateKey: string, claims: Record<string, unknown>) {
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({ iss: clientEmail, ...claims }));
  const unsignedToken = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsignedToken),
  );
  return `${unsignedToken}.${base64Url(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string) {
  const normalized = pem.replace(/\\n/g, "\n");
  const b64 = normalized
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function base64Url(value: string | Uint8Array) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function stringifyData(data: Record<string, unknown>) {
  const output: Record<string, string> = {};
  for (const [key, value] of Object.entries(data)) {
    if (value !== null && value !== undefined) output[key] = String(value);
  }
  return output;
}

async function supabaseGet<T>(path: string): Promise<T> {
  const response = await fetch(`${supabaseUrl}${path}`, { headers: supabaseHeaders() });
  if (!response.ok) throw new Error(await response.text());
  return await response.json();
}

async function supabasePost(path: string, body: unknown, prefer = "return=minimal") {
  const response = await fetch(`${supabaseUrl}${path}`, {
    method: "POST",
    headers: { ...supabaseHeaders(), "Content-Type": "application/json", Prefer: prefer },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function supabasePatch(path: string, body: Record<string, unknown>) {
  const response = await fetch(`${supabaseUrl}${path}`, {
    method: "PATCH",
    headers: { ...supabaseHeaders(), "Content-Type": "application/json", Prefer: "return=minimal" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());
}

function supabaseHeaders() {
  return { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` };
}

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
