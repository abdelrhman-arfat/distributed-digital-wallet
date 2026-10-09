import app from './app';
import { PORT } from './config/env.config';

app.listen(PORT, () => {
  console.log('app is runngin on port : ', PORT);
});