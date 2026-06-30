// API route tests. pg and redis are mocked so these run without a real
// database or Redis (e.g. in CI). We import the Express `app` from server.js
// (which no longer auto-listens when required as a module).

jest.mock("pg", () => {
    const mPool = { query: jest.fn(), end: jest.fn() };
    return { Pool: jest.fn(() => mPool), __mPool: mPool };
});

jest.mock("redis", () => {
    const mClient = {
        on: jest.fn(),
        connect: jest.fn().mockResolvedValue(undefined),
        isOpen: true,
        ping: jest.fn().mockResolvedValue("PONG"),
        lPush: jest.fn().mockResolvedValue(1),
        quit: jest.fn().mockResolvedValue(undefined)
    };
    return { createClient: jest.fn(() => mClient), __mClient: mClient };
});

const request = require("supertest");
const { __mPool } = require("pg");
const { __mClient } = require("redis");
const { app } = require("../src/server");

beforeEach(() => {
    jest.clearAllMocks();
    __mClient.isOpen = true;
    __mClient.connect.mockResolvedValue(undefined);
    __mClient.ping.mockResolvedValue("PONG");
    __mClient.lPush.mockResolvedValue(1);
    __mPool.query.mockResolvedValue({ rows: [] });
});

describe("health & readiness", () => {
    test("GET /healthz -> 200 ok", async () => {
        const res = await request(app).get("/healthz");
        expect(res.status).toBe(200);
        expect(res.body).toEqual({ status: "ok", service: "api" });
    });

    test("GET /readyz -> 200 ready when pg + redis are healthy", async () => {
        const res = await request(app).get("/readyz");
        expect(res.status).toBe(200);
        expect(res.body.status).toBe("ready");
    });

    test("GET /readyz -> 503 not-ready when the database is down", async () => {
        __mPool.query.mockRejectedValueOnce(new Error("db down"));
        const res = await request(app).get("/readyz");
        expect(res.status).toBe(503);
        expect(res.body.status).toBe("not-ready");
    });
});

describe("GET /events", () => {
    test("returns the seeded events list", async () => {
        const res = await request(app).get("/events");
        expect(res.status).toBe(200);
        expect(Array.isArray(res.body)).toBe(true);
        expect(res.body.length).toBeGreaterThan(0);
        expect(res.body[0]).toHaveProperty("id");
        expect(res.body[0]).toHaveProperty("availableTickets");
    });
});

describe("POST /tickets/purchase", () => {
    test("400 when required fields are missing", async () => {
        const res = await request(app).post("/tickets/purchase").send({ eventId: "evt-1001" });
        expect(res.status).toBe(400);
        expect(__mClient.lPush).not.toHaveBeenCalled();
    });

    test("404 when the event does not exist", async () => {
        const res = await request(app)
            .post("/tickets/purchase")
            .send({ eventId: "evt-does-not-exist", customerEmail: "a@b.com", quantity: 1 });
        expect(res.status).toBe(404);
        expect(__mClient.lPush).not.toHaveBeenCalled();
    });

    test("400 when quantity is not a positive integer", async () => {
        const res = await request(app)
            .post("/tickets/purchase")
            .send({ eventId: "evt-1001", customerEmail: "a@b.com", quantity: -1 });
        expect(res.status).toBe(400);
        expect(__mClient.lPush).not.toHaveBeenCalled();
    });

    test("202 and enqueues the order to Redis on a valid request", async () => {
        const res = await request(app)
            .post("/tickets/purchase")
            .send({ eventId: "evt-1001", customerEmail: "a@b.com", quantity: 2 });
        expect(res.status).toBe(202);
        expect(res.body).toHaveProperty("orderId");
        expect(__mClient.lPush).toHaveBeenCalledTimes(1);

        const [queueName, payload] = __mClient.lPush.mock.calls[0];
        expect(queueName).toBe("ticket_orders");
        expect(JSON.parse(payload)).toMatchObject({
            eventId: "evt-1001",
            customerEmail: "a@b.com",
            quantity: 2,
            status: "queued"
        });
    });

    test("500 when Redis enqueue fails", async () => {
        __mClient.lPush.mockRejectedValueOnce(new Error("redis down"));
        const res = await request(app)
            .post("/tickets/purchase")
            .send({ eventId: "evt-1001", customerEmail: "a@b.com", quantity: 1 });
        expect(res.status).toBe(500);
    });
});

describe("GET /tickets/orders", () => {
    test("returns rows from the database", async () => {
        __mPool.query.mockResolvedValueOnce({
            rows: [
                { order_id: "ord-1", event_id: "evt-1001", customer_email: "a@b.com", quantity: 1, status: "processed" }
            ]
        });
        const res = await request(app).get("/tickets/orders");
        expect(res.status).toBe(200);
        expect(res.body[0].order_id).toBe("ord-1");
        expect(res.body[0].status).toBe("processed");
    });

    test("500 when the query fails", async () => {
        __mPool.query.mockRejectedValueOnce(new Error("query failed"));
        const res = await request(app).get("/tickets/orders");
        expect(res.status).toBe(500);
    });
});
