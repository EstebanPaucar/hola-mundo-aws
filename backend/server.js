const express = require('express');
const app = express();
const port = 80; // Escuchamos en el puerto 80 dentro del contenedor

app.get('/', (req, res) => {
    res.json({
        mensaje: "Hola desde el Backend (Cuenta AWS 2)",
        estado: "Activo",
        instance_id: Math.floor(Math.random() * 10000), // Simula ID de instancia
        timestamp: new Date().toISOString()
    });
});

app.listen(port, () => {
    console.log(`Backend escuchando en el puerto ${port}`);
});