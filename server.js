#!/usr/bin/env node

import express from 'express';
import os from 'os';

const app = express();
const PORT = process.env.PORT || 3000;
const ENV = process.env.NODE_ENV || 'development';

// Basic middleware
app.use(express.json());

// Health check route
app.get('/', (req, res) => {
  res.json({
    message: '🚀 Auto-deploy test successful!',
    environment: ENV,
    hostname: os.hostname(),
    timestamp: new Date().toISOString(),
  });
});

// Example API route
app.get('/api/info', (req, res) => {
  res.json({
    uptime: process.uptime(),
    memoryUsage: process.memoryUsage(),
  });
});

// Start server
const server = app.listen(PORT, () => {
  console.log(`✅ Server running on port ${PORT} in ${ENV} mode`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('🛑 Gracefully shutting down...');
  server.close(() => {
    console.log('Server stopped');
    process.exit(0);
  });
});
