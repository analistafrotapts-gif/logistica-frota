// Gera a chave de servidor do módulo (64 caracteres hexadecimais).
import { randomBytes } from 'node:crypto';
console.log(randomBytes(32).toString('hex'));
