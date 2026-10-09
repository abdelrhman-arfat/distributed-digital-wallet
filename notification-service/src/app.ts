import express from 'express';
import helmet from 'helmet';
import { Request, Response } from 'express';
import cors from 'cors';

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true }));

app.get('/health', (_req, res) => {
  res.status(200).json({
    status: 'ok',
    service: 'notification-service',
  });
});

app.get('/', (_req: Request, res: Response) => {
  return res.send('<h1>hello</h1>');
});

app.use((_req, res) => {
  res.status(404).json({
    message: 'Route not found',
  });
});

app.use((err: Error, _req: express.Request, res: express.Response) => {
  // TODO: Loggers
  console.log(err.message);
  res.status(500).json({
    message: 'Internal server error',
  });
});

export default app;
