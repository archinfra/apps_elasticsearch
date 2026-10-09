{{- define "archinfra.fullname" -}}{{ .Release.Name }}{{- end -}}
{{- define "archinfra.esname" -}}{{ .Release.Name }}-es{{- end -}}
{{- define "archinfra.headless" -}}{{ .Release.Name }}-es-headless{{- end -}}
{{- define "archinfra.tls" -}}{{ .Release.Name }}-tls{{- end -}}
{{- define "archinfra.auth" -}}{{ .Values.auth.existingSecret }}{{- end -}}
{{- define "archinfra.eshttp" -}}{{ .Release.Name }}-es{{- end -}}
{{- define "archinfra.eshost" -}}{{ .Release.Name }}-es.{{ .Release.Namespace }}.svc.cluster.local{{- end -}}
{{- define "archinfra.image" -}}{{ printf "%s/%s:%s" .registry .name .tag }}{{- end -}}
