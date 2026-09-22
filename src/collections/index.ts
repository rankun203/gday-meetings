import { audioDirectory } from '../server/storage'
import { prepareAudio, audioMetadata } from '../server/audio-hooks'
import type { Access, CollectionConfig } from 'payload'
const authenticated: Access = ({ req }) =>
  Boolean(req.user && !req.user.disabled)
const access = {
  read: authenticated,
  create: authenticated,
  update: authenticated,
  delete: authenticated,
}
export const Users: CollectionConfig = {
  slug: 'users',
  auth: {
    strategies: [
      {
        name: 'gday-session',
        authenticate: async ({ headers }) => {
          const { getBrowserPrincipal, authIssuer } =
            await import('../server/auth')
          const principal = await getBrowserPrincipal(
            new Request(authIssuer(), { headers }),
          )
          return {
            user: principal
              ? { ...principal.user, collection: 'users' as const }
              : null,
          }
        },
      },
    ],
  },
  access: {
    create: ({ req }) => req.user?.role === 'admin' && !req.user.disabled,
    read: ({ req }) =>
      req.user?.role === 'admin' && !req.user.disabled
        ? true
        : req.user && !req.user.disabled
          ? { id: { equals: req.user.id } }
          : false,
    update: ({ req }) =>
      req.user?.role === 'admin' && !req.user.disabled
        ? true
        : req.user && !req.user.disabled
          ? { id: { equals: req.user.id } }
          : false,
    delete: ({ req }) => req.user?.role === 'admin' && !req.user.disabled,
    admin: ({ req }) => req.user?.role === 'admin' && !req.user.disabled,
  },
  admin: { useAsTitle: 'email' },
  hooks: {
    beforeLogin: [
      ({ user }) => {
        if (user.disabled) throw new Error('Account disabled')
        return user
      },
    ],
    beforeChange: [
      async ({ data, operation, req }) => {
        if (operation === 'create' && !req.user) {
          const count = await req.payload.count({
            collection: 'users',
            overrideAccess: true,
            req,
          })
          if (count.totalDocs === 0) data.role = 'admin'
        }
        return data
      },
    ],
  },
  fields: [
    {
      name: 'role',
      type: 'select',
      options: ['admin', 'member'],
      defaultValue: 'member',
      required: true,
      access: {
        update: ({ req }) => req.user?.role === 'admin' && !req.user.disabled,
      },
    },
    {
      name: 'disabled',
      type: 'checkbox',
      defaultValue: false,
      access: {
        update: ({ req }) => req.user?.role === 'admin' && !req.user.disabled,
      },
    },
  ],
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
  access: {
    ...access,
    create: ({ req }) =>
      Boolean(
        req.user &&
        !req.user.disabled &&
        req.context.validatedTaskSubmission === true,
      ),
  },
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
      access: { update: () => false },
      required: true,
      defaultValue: 'PENDING',
      options: ['PENDING', 'COMPLETED', 'FAILED'],
    },
    {
      name: 'inputs',
      type: 'array',
      access: { update: () => false },
      fields: [
        { name: 'url', type: 'text', required: true },
        { name: 'trackName', type: 'text' },
        { name: 'sourceType', type: 'text' },
        { name: 'channels', type: 'number' },
      ],
    },
    { name: 'outputs', type: 'join', collection: 'outputs', on: 'task' },
    { name: 'error', type: 'textarea', access: { update: () => false } },
    {
      name: 'runpodJobId',
      type: 'text',
      index: true,
      access: { update: () => false },
    },
    {
      name: 'executionState',
      access: { update: () => false },
      type: 'text',
      index: true,
      admin: { readOnly: true },
    },
    {
      name: 'executionOptions',
      type: 'json',
      admin: { readOnly: true },
      access: { update: () => false },
    },
    {
      name: 'executionRevision',
      access: { update: () => false },
      type: 'number',
      defaultValue: 0,
      admin: { readOnly: true },
    },
    {
      name: 'submissionStartedAt',
      type: 'date',
      admin: { readOnly: true },
      access: { update: () => false },
    },
    {
      name: 'nextPollAt',
      access: { update: () => false },
      type: 'date',
      index: true,
      admin: { readOnly: true },
    },
    {
      name: 'idempotencyKey',
      access: { update: () => false },
      type: 'text',
      unique: true,
      index: true,
      admin: { hidden: true },
    },
    {
      name: 'requestHash',
      type: 'text',
      admin: { hidden: true },
      access: { update: () => false },
    },
  ],
}
export const Outputs: CollectionConfig = {
  slug: 'outputs',
  access: { ...access, create: () => false, update: () => false },
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
  disableDuplicate: true,
  upload: {
    staticDir: audioDirectory(),
    mimeTypes: [
      'audio/*',
      'video/mp4',
      'video/webm',
      'application/octet-stream',
    ],
    filesRequiredOnCreate: true,
    pasteURL: false,
    crop: false,
    focalPoint: false,
  },
  hooks: { beforeOperation: [prepareAudio], beforeValidate: [audioMetadata] },
  admin: {
    useAsTitle: 'originalName',
    defaultColumns: ['originalName', 'filesize', 'createdAt'],
    description:
      'Upload recordings here. Gday manages file storage and metadata automatically.',
  },
  fields: [
    {
      name: 'storageKey',
      type: 'text',
      required: true,
      unique: true,
      admin: { hidden: true },
    },
    {
      name: 'originalName',
      type: 'text',
      required: true,
      admin: { hidden: true },
    },
    { name: 'size', type: 'number', required: true, admin: { hidden: true } },
    {
      name: 'contentType',
      type: 'text',
      required: true,
      admin: { hidden: true },
    },
  ],
}
