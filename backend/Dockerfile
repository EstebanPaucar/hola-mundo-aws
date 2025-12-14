# Usamos una imagen ligera de Node
FROM node:alpine

# Directorio de trabajo
WORKDIR /app

# Copiamos los archivos de configuración
COPY package*.json ./

# Instalamos dependencias
RUN npm install

# Copiamos el resto del código
COPY . .

# Exponemos el puerto 80 (igual que tu frontend para simplificar los Security Groups)
EXPOSE 80

# Comando de inicio
CMD ["npm", "start"]