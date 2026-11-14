export function normalizeEgyptianMobile(value: unknown): string | null {
  let digits = String(value ?? '').replace(/[\s\-()]/g, '');
  if (digits.startsWith('+')) digits = digits.slice(1);
  if (!/^\d+$/.test(digits)) return null;

  if (digits.startsWith('00')) digits = digits.slice(2);
  if (digits.startsWith('0')) digits = `20${digits.slice(1)}`;
  else if (/^1[0125]/.test(digits)) digits = `20${digits}`;

  return /^20(10|11|12|15)\d{8}$/.test(digits) ? digits : null;
}
