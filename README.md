Distributed Microservices Demo Suite
-
This project is a demo of a system split into independent parts that work together. It focuses on how a network stays organized, secure, and handles failures.

The Microservices
-
Gateway (Node.js): handles all incoming requests and routes them to the correct service. It serves as the single entry point for traffic and logging metadata to MongoDB.

Health Node (Go): keeps track of the other services and works in tandem with Gateway to ensure the entire system is online and responsive.
  *
  Handling Failures
  In a basic setup, the Gateway and Health Node are "single points of failure." To fix this in a real-world version:
  
  Redundancy: I would run multiple Gateways. If one fails, another takes over instantly.
  
  Consensus: I would use a cluster of Health Nodes that "vote" on a leader. If the leader crashes, the others elect       a new one, so the monitoring never stops.
  *
  
Invoice Service (Python): A business-logic service focused on creating and formatting assets.  

Performance Monitor (C): tracks raw system resources.  

Folder Structure
-
Each service is self-contained in its own directory to allow independent development and deployment:

/api-gateway
/invoice-service
/performance-monitor
/health-node
