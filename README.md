# curatering-mobile

Monorepo with a Flutter client and a Node API backed by SQLite.

## Layout

| Package | Path | Role |
|--------|------|------|
| **Frontend** | [`packages/frontend`](packages/frontend) | Flutter app (`curatering_mobile`) |
| **Backend** | [`packages/backend`](packages/backend) | Express server + SQLite file database |

## Frontend

```bash
cd packages/frontend
flutter pub get
flutter run
```

## Backend

```bash
cd packages/backend
npm install
cp .env.example .env
npm run dev
```

The API listens on `http://localhost:8080` by default. Point the Flutter app at that base URL when you wire up networking.
