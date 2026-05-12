const http = require('http');
const httpProxy = require('http-proxy');
const mongoose = require('mongoose');

// Standard MongoDB connection
mongoose.connect('mongodb+srv://cluster-url/micro_logs');
const Log = mongoose.model('Log', { service: String, timestamp: Date });

const proxy = httpProxy.createProxyServer({});
const routes = {
    '/generate': 'http://localhost:8081',
    '/metrics': 'http://localhost:8082',
    '/status': 'http://localhost:8083'
};

const server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    const target = routes[path];

    if (target) {
        new Log({ service: path, timestamp: new Date() }).save();[cite: 3]
        proxy.web(req, res, { target });
    } else {
        res.writeHead(404);
        res.end('Not Found');
    }
});

server.listen(8080);
