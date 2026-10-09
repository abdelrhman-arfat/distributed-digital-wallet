import 'dotenv/config';

const ENV = {
  PORT: Number(process.env.PORT) || 3000,
};

export const { PORT } = ENV;