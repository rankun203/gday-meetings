import { removeAudio } from '../server/storage'
import type { Access, CollectionConfig } from 'payload'
const authenticated: Access = ({ req }) => Boolean(req.user)
const access = {
  read: authenticated,
  create: authenticated,
  update: authenticated,
  delete: authenticated,
}
export const Users: CollectionConfig = {
  slug: 'users',
  auth: true,
  access,
  admin: { useAsTitle: 'email' },
  fields: [],
}
export const Meetings: CollectionConfig = {
  slug: 'meetings',
  access,
  admin: {
    useAsTitle: 'title',
    defaultColumns: ['title', 'externalId', 'updatedAt'],
    listSearchableFields: ['title', 'transcript'],
  },
  fields: [
    {
      name: 'externalId',
      type: 'text',
      required: true,
      unique: true,
      index: true,
    },
    { name: 'title', type: 'text', required: true },
    { name: 'transcript', type: 'textarea' },
    {
      name: 'transcriptTaskOrder',
      type: 'text',
      admin: { hidden: true },
      access: { update: () => false },
    },
    { name: 'recordedAt', type: 'date' },
  ],
}
export const Tasks: CollectionConfig = {
  slug: 'tasks',
  access,
  admin: {
    useAsTitle: 'id',
    defaultColumns: ['meeting', 'status', 'createdAt'],
  },
  fields: [
    {
      name: 'meeting',
      type: 'relationship',
      relationTo: 'meetings',
      required: true,
      index: true,
    },
    {
      name: 'status',
      type: 'select',
      required: true,
      defaultValue: 'PENDING',
      options: ['PENDING', 'COMPLETED', 'FAILED'],
    },
    {
      name: 'inputs',
      type: 'array',
      fields: [
        { name: 'url', type: 'text', required: true },
        { name: 'trackName', type: 'text' },
        { name: 'sourceType', type: 'text' },
        { name: 'channels', type: 'number' },
      ],
    },
    { name: 'outputs', type: 'join', collection: 'outputs', on: 'task' },
    { name: 'error', type: 'textarea' },
    { name: 'runpodJobId', type: 'text', index: true },
  ],
}
export const Outputs: CollectionConfig = {
  slug: 'outputs',
  access: { ...access, update: () => false },
  admin: {
    useAsTitle: 'key',
    defaultColumns: ['type', 'task', 'createdAt'],
    description:
      'Durable immutable worker results. Retried callbacks return the original result.',
  },
  fields: [
    { name: 'key', type: 'text', required: true, unique: true, index: true },
    {
      name: 'task',
      type: 'relationship',
      relationTo: 'tasks',
      required: true,
      index: true,
    },
    { name: 'type', type: 'text', required: true },
    { name: 'body', type: 'json', required: true },
  ],
}
export const AudioFiles: CollectionConfig = {
  slug: 'audio-files',
  access,
  hooks: {
    afterDelete: [
      async ({ doc }) => {
        await removeAudio(String(doc.storageKey))
      },
    ],
  },
  admin: {
    useAsTitle: 'originalName',
    defaultColumns: ['originalName', 'size', 'createdAt'],
  },
  fields: [
    { name: 'storageKey', type: 'text', required: true, unique: true },
    { name: 'originalName', type: 'text', required: true },
    { name: 'size', type: 'number', required: true },
    { name: 'contentType', type: 'text', required: true },
  ],
}
